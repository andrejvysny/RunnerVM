import Foundation
import GitHubControl
import GuestControl
import RPC
import RunnerCore
import Testing

@testable import Orchestration

/// WP7/WP10: the GitHub-API-fault slice of the live E2E fault matrix (`scripts/live-github-e2e.sh`,
/// `scenario-scaleset-reconnect` and friends), exercised here against the fakes instead of a real
/// GitHub.com outage. Every test asserts as many of the matrix's six properties as apply to it: no
/// duplicate job, no duplicate `AcquireJobs`, no orphan registration, no orphan session, no orphan
/// VM, demand/capacity converges.
///
/// `FakeScaleSetControlPlane` (`Sources/GitHubControl/Testing/FakeScaleSetControlPlane.swift`)
/// fakes the `ScaleSetControlPlane` *protocol*, not the transport (see its own doc comment): calls
/// through it never reach `ActionsServiceConnection`/`GitHubHTTPClient`, so
/// `runnervm_github_requests_total{class}` (`Sources/Orchestration/MetricsGitHubRequestObserver.swift`,
/// `Sources/GitHubControl/HTTP/GitHubRequestObserver.swift`) never increments here. The 429 test
/// below says so explicitly and skips that assertion, per the task's own escape hatch, rather than
/// asserting a metric this path cannot produce.
///
/// Related existing coverage (extended here rather than duplicated):
/// - `RunnerSessionTests.aFailedJITRequestEndsTheSessionAsJitFailed` already covers a JIT 5xx on
///   the **REST** `generate-jitconfig` path. `aFailedScaleSetJITRequestLeavesNoRegistration` below
///   covers the same failure shape on the **scale-set** `generateJITConfig` path
///   (`FakeScaleSetControlPlane.failJITConfig`), which a scale-set-fronted profile actually uses
///   and which had no coverage.
/// - `RunnerSessionTests.aRefusedStartRunnerRemovesTheRunnerFromGitHub` already covers a refused
///   `agent.startRunner` on the **REST** JIT path with a best-effort ("eventually one DELETE")
///   assertion. `guestStartupFailureRemovesTheScaleSetRunnerExactlyOnceAndDemandConverges` below
///   covers the same failure on the **scale-set** path, asserts the removal happened *exactly*
///   once, and additionally proves demand converges back to zero once GitHub's own statistics
///   reflect the failure (rather than only checking session/instance state).
@Suite struct GitHubFaultTests {
  // MARK: - 1: GitHub API timeout during getMessage

  @Test func getMessageTimeoutBacksOffAndDeliversTheJobExactlyOnce() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      let log = DemandEventLog(provider.events)
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      let messageID = try await injectPollFailureThenDeliver(
        harness, scaleSetID: scaleSetID, failures: ["the operation timed out"],
        job: jobMessage(.jobAvailable, request: 7))

      try await waitUntil("the job to be delivered once the provider recovers") {
        harness.scaleSetPlane.deletedMessageIDs().contains(messageID)
      }

      // No duplicate job / no duplicate AcquireJobs: the timeout happened before the job was ever
      // visible to a successful poll, so exactly one AcquireJobs call for exactly the one job.
      #expect(harness.scaleSetPlane.acquireCalls().count == 1)
      #expect(harness.scaleSetPlane.acquiredIDs() == [7])
      #expect(log.events.contains { if case .providerDegraded = $0 { true } else { false } })
      // No orphan session: the provider reconnected (new generation) rather than sticking closed.
      let session = try #require(try await harness.scaleSets.currentSession(scaleSetId: row.id))
      #expect(session.state == "open")
      #expect((session.sessionGeneration ?? 0) >= 1)
      // No orphan registration / no orphan VM: N/A at this layer -- no runner session or instance
      // is created by the demand provider alone.
      // Demand converges: the snapshot reflects the statistics the recovered session carried.
      let snapshot = await provider.snapshot(profile: profile)
      #expect(snapshot.healthy)
      #expect(snapshot.assignedJobs == 1)
      await provider.stop()
      log.stop()
    }
  }

  // MARK: - 2: 429 rate-limited getMessage (Retry-After)

  @Test func rateLimitedPollRetriesAcrossMultipleAttemptsWithoutDuplicateAcquisition() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      let log = DemandEventLog(provider.events)
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      // Two 429s in a row: GitHub keeps saying "come back later" for more than one attempt before
      // the session is let back in, so the provider must survive consecutive, not just single,
      // rate-limit responses.
      let messageID = try await injectPollFailureThenDeliver(
        harness, scaleSetID: scaleSetID,
        failures: ["429 rate limited (Retry-After)", "429 rate limited (Retry-After)"],
        job: jobMessage(.jobAvailable, request: 9))

      try await waitUntil("the job to be delivered once the rate limit clears") {
        harness.scaleSetPlane.deletedMessageIDs().contains(messageID)
      }

      #expect(harness.scaleSetPlane.acquireCalls().count == 1)
      #expect(harness.scaleSetPlane.acquiredIDs() == [9])
      let degradedCount = log.events.count { if case .providerDegraded = $0 { true } else { false } }
      #expect(degradedCount >= 2)
      let session = try #require(try await harness.scaleSets.currentSession(scaleSetId: row.id))
      #expect(session.state == "open")
      let snapshot = await provider.snapshot(profile: profile)
      #expect(snapshot.healthy)
      #expect(snapshot.assignedJobs == 1)
      // `runnervm_github_requests_total{class="rate_limited"}` is deliberately not asserted here:
      // see the file header -- FakeScaleSetControlPlane never drives the observer that records it.
      await provider.stop()
      log.stop()
    }
  }

  // MARK: - 3: 5xx on the scale-set generate-jitconfig

  @Test func aFailedScaleSetJITRequestLeavesNoRegistration() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      harness.scaleSetPlane.failJITConfig("500: server error")
      let (instance, agent) = try await harness.idleInstance()

      await #expect(throws: (any Error).self) {
        _ = try await harness.runners.startSession(
          instanceId: instance.id, origin: .scaleSet(id: 777))
      }

      let sessions = try await harness.runners.list()
      #expect(sessions.count == 1)
      #expect(sessions.first?.state == .jitFailed)
      #expect(sessions.first?.jitSource == .scaleSet)
      // No orphan registration: the JIT call never returned a runner id, so there is nothing on
      // GitHub to remove, and the fake recorded no removal.
      #expect(sessions.first?.githubRunnerId == nil)
      #expect(harness.scaleSetPlane.removedRunners().isEmpty)
      #expect(harness.scaleSetPlane.jitCalls().count == 1)
      // No orphan VM: the instance is freed back from its claim rather than stuck "busy" forever.
      try await harness.awaitInstance(instance.id, state: .interrupted)
      await agent.stop()
    }
  }

  // MARK: - 4: JIT issued, guest startup fails

  @Test func guestStartupFailureRemovesTheScaleSetRunnerExactlyOnceAndDemandConverges() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.failures[.startRunner] = RPCErrorPayload(
        code: "INTERNAL", message: "no runner user on this image")
      let (instance, agent) = try await harness.idleInstance(script: script)

      let provider = harness.demandProvider()
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)
      let orchestrator = await harness.orchestrator(demand: provider)

      // GitHub hands the scale set one job.
      let jobMsg = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, jobs: [jobMessage(.jobAvailable, request: 55)],
        statistics: statistics(assigned: 1))
      try await waitUntil("the job to be acquired") {
        harness.scaleSetPlane.deletedMessageIDs().contains(jobMsg)
      }
      try await waitUntil("demand to reach the orchestrator") {
        await provider.snapshot(profile: profile).assignedJobs == 1
      }

      await orchestrator.tick()
      await orchestrator.drainStarts()

      let session = try #require(try await harness.runners.list().first)
      #expect(session.state == .runnerStartFailed)
      #expect(session.jitSource == .scaleSet)
      let runnerID = try #require(session.githubRunnerId)
      // Exactly once: one failed start must not fan out into repeated removal attempts.
      #expect(harness.scaleSetPlane.removedRunners() == [runnerID])
      // No orphan VM: the VM is interrupted (kept for diagnosis by design), not left "busy".
      try await harness.awaitInstance(instance.id, state: .interrupted)

      // Demand/capacity converges: once GitHub's own statistics reflect that nothing is assigned
      // any more (the runner registration is gone; the job was never served), the provider's
      // snapshot follows -- it does not stay pinned at the stale "1" the failed attempt saw.
      let settled = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, statistics: statistics(assigned: 0))
      try await waitUntil("demand to converge back to zero") {
        guard harness.scaleSetPlane.deletedMessageIDs().contains(settled) else { return false }
        return await provider.snapshot(profile: profile).assignedJobs == 0
      }

      // No duplicate job / no orphan VM: with demand back at zero, the next pass must not spin up
      // a replacement for a job that is no longer outstanding.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceCount(profile: "linux") == 1)
      // Still exactly once: the convergence poll must not have triggered a second removal.
      #expect(harness.scaleSetPlane.removedRunners() == [runnerID])

      await provider.stop()
      await agent.stop()
    }
  }

  // MARK: - 5: the JIT deadline (`timeouts.jitGeneration`, spec §73)

  /// GitHub accepting the POST and never answering used to park `register` — and the VM it had
  /// already claimed — until the daemon was restarted: nothing in `jit*` has an observer, so no
  /// deadline sweep could reach it either.
  @Test func aScaleSetJITThatNeverAnswersFailsTheSessionAtTheDeadline() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(jitGeneration: .milliseconds(50))
    ) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      harness.scaleSetPlane.stallJITConfig(for: 777)

      do {
        _ = try await harness.runners.startSession(
          instanceId: instance.id, origin: .scaleSet(id: 777))
        Issue.record("a stalled generate-jitconfig must not produce a session")
      } catch let error as GitHubControlError {
        #expect(error.code == "GITHUB_JIT_GENERATION_TIMEOUT")
      }

      let session = try #require(try await harness.runners.list().first)
      #expect(session.state == .jitFailed)
      #expect(session.jitSource == .scaleSet)
      #expect(session.failureCode == "GITHUB_JIT_GENERATION_TIMEOUT")
      // No orphan registration: the call was cancelled before the service ever answered, and the
      // name lookup that follows finds nothing either.
      #expect(session.githubRunnerId == nil)
      #expect(harness.scaleSetPlane.removedRunners().isEmpty)
      // No orphan VM, and nothing retained: a slow GitHub says nothing about this guest, so the
      // capacity comes back now instead of after `failedInstanceRetention`.
      try await harness.awaitInstance(instance.id, state: .deleted)
      await harness.scaleSetPlane.releaseJITConfig()
      await agent.stop()
    }
  }

  /// The other half of the same race. The deadline can expire while the config is already on its
  /// way back, and then GitHub holds a registration the caller never used: the id the JIT call
  /// published on its way out is the only handle on it.
  @Test func aScaleSetJITConfigThatArrivesAfterTheDeadlineIsRemoved() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(jitGeneration: .milliseconds(50))
    ) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      harness.scaleSetPlane.stallJITConfig(for: 777, .pastCancellation)

      do {
        _ = try await harness.runners.startSession(
          instanceId: instance.id, origin: .scaleSet(id: 777))
        Issue.record("a late generate-jitconfig must not produce a session either")
      } catch let error as GitHubControlError {
        #expect(error.code == "GITHUB_JIT_GENERATION_TIMEOUT")
      }

      let session = try #require(try await harness.runners.list().first)
      #expect(session.state == .jitFailed)
      #expect(session.failureCode == "GITHUB_JIT_GENERATION_TIMEOUT")
      // The id reached the row, so the removal ran from the row -- exactly once, bracketed by its
      // operation -- and `retryPendingRemovals` has the column it needs had that DELETE failed.
      let runnerID = try #require(session.githubRunnerId)
      #expect(harness.scaleSetPlane.removedRunners() == [runnerID])
      #expect(harness.scaleSetPlane.jitCalls().count == 1)
      try await harness.awaitInstance(instance.id, state: .deleted)
      await agent.stop()
    }
  }

  /// The one case that goes through the *real* `ActionsServiceConnection`.
  ///
  /// `FakeScaleSetControlPlane` fakes the protocol, so it can prove what the deadline does but not
  /// that the scale-set path is cancellable at all: the shared token exchange used to be awaited as
  /// `Task.value`, which is not a cancellation point, and a 200 ms deadline over it returned after
  /// 3.2 s with the whole task group parked. Only wall-clock time can tell that apart, so this case
  /// stalls the exchange for ten seconds and asserts the deadline still returns in well under one.
  @Test func aStalledTokenExchangeIsAbandonedAtTheDeadlineNotWaitedOut() async throws {
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let scope = GitHubScope.repository(owner: "acme", repository: "app")
    let registrationTokenPath = M2Harness.runnersPath + "/registration-token"
    let exchangePath = "/actions/runner-registration"
    github.stub(
      .post, registrationTokenPath,
      .json("{\"token\":\"registration-token\"}", delay: .seconds(10)))
    let http = GitHubHTTPClient(
      baseURL: github.baseURL, credentials: StaticCredentialProvider(token: M2Harness.token),
      session: github.makeSession(),
      options: GitHubHTTPClient.Options(retryPolicy: RetryPolicy(maxAttempts: 1)))
    let client = ActionsScaleSetClient(
      http: http, apiBaseURL: github.baseURL, configBaseURL: github.baseURL,
      session: github.makeSession(),
      options: ActionsServiceOptions(retryPolicy: RetryPolicy(maxAttempts: 1)))

    // A warm-up caller starts the exchange and parks in its first leg. The race below is only
    // entered once the fake has actually recorded that POST, so the deadline cannot fire before
    // `URLSession` has dispatched anything -- which under a saturated `--parallel` run it otherwise
    // does, leaving the first-leg count at 0. It also puts the measured caller on the path that
    // matters: parking on somebody else's in-flight exchange.
    let warmUp = Task {
      try await client.generateJITConfig(
        scope: scope, scaleSetID: 1, runnerName: "rvm-warmup", workFolder: "_work")
    }
    try await waitUntil("the token exchange to be in flight") {
      !github.requests(.post, registrationTokenPath).isEmpty
    }

    let started = ContinuousClock.now
    do {
      _ = try await withDeadline(
        .milliseconds(100), expired: { GitHubControlError.jitGenerationTimeout(seconds: 0.1) }
      ) {
        try await client.generateJITConfig(
          scope: scope, scaleSetID: 1, runnerName: "rvm-runner", workFolder: "_work")
      }
      Issue.record("the stalled exchange must not have produced a JIT config")
    } catch let error as GitHubControlError {
      #expect(error.code == "GITHUB_JIT_GENERATION_TIMEOUT")
    }
    // Ordering first, because it does not depend on how loaded the machine is: the exchange only
    // reaches its second leg once the first one has answered, so a caller that was still waiting
    // for GitHub would have seen that leg happen before it was let go.
    #expect(github.requests(.post, exchangePath).isEmpty)
    // Exactly one: the deadline caller parked on the warm-up's exchange rather than starting a
    // second one, which is the sharing the cancellable waiter has to preserve.
    #expect(github.requests(.post, registrationTokenPath).count == 1)
    // And the stopwatch the design asks for, loose enough for a saturated `--parallel` run (a
    // 100 ms deadline has been seen to land ~2 s late there) but still well under the 10 s stall
    // the un-cancellable version waited out in full.
    let elapsed = started.duration(to: .now)
    #expect(elapsed < .seconds(5), "the deadline returned after \(elapsed)")

    // Never leave the warm-up running past the test: cancelling it drops its waiter (the shared
    // exchange itself is deliberately not cancellable by a caller, and simply finishes unwatched).
    warmUp.cancel()
    _ = try? await warmUp.value
  }
}

/// Queues one scripted failure per entry in `failures` for `scaleSetID`'s long poll, then enqueues
/// `job` behind them, and returns `job`'s message id.
///
/// `FakeScaleSetControlPlane.nextMessage` (the fake's `getMessage`) checks its one-shot failure
/// queue exactly once, at the very start of each call, and otherwise blocks until a message is
/// queued -- it never re-checks the failure queue while blocked (see the file header on why this
/// matters). By the time this is called, the profile's very first long poll is already in flight
/// and has therefore already passed that check with nothing queued, so:
///
/// 1. A harmless statistics-only heartbeat is queued first: the in-flight poll (which cannot be
///    made to fail any more) returns it instead of ever seeing `job`.
/// 2. The scripted failures are already queued by the time that poll's *next* call starts, so that
///    call -- and, if there is more than one failure, every call after it up to the last -- times
///    out for real, forcing `ScaleSetDemandProvider.degrade` and a fresh session/generation.
/// 3. Only once every scripted failure has been consumed does a poll reach the queue and find
///    `job`, so it is delivered exactly once, never on the same call that was made to fail.
private func injectPollFailureThenDeliver(
  _ harness: M2Harness, scaleSetID: Int64, failures: [String], job: ScaleSetJobMessage
) async throws -> Int64 {
  try await waitUntil("the first long poll to be in flight") {
    harness.scaleSetPlane.getMessageCalls().contains { $0.scaleSetID == scaleSetID }
  }
  for message in failures {
    harness.scaleSetPlane.failNextPoll(scaleSetID: scaleSetID, message)
  }
  harness.scaleSetPlane.enqueue(scaleSetID: scaleSetID, statistics: statistics(assigned: 0))
  return harness.scaleSetPlane.enqueue(
    scaleSetID: scaleSetID, jobs: [job], statistics: statistics(assigned: 1))
}
