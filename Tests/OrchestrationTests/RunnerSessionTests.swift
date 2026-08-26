import DaemonAPI
import Foundation
import GitHubControl
import GuestControl
import Persistence
import RPC
import RunnerCore
import Testing

@testable import Orchestration

/// The M5 slice end to end: JIT registration, secret delivery over the guest socket, the runner
/// state machine, and what each terminal state does about GitHub and the VM (spec §36, §47, §48).
@Suite struct RunnerSessionTests {
  /// `starting -> online -> busy -> exited`, one answer per `agent.runnerStatus` poll.
  private static func script(_ states: [RunnerProcessState]) -> FakeGuestAgent.Script {
    var script = FakeGuestAgent.Script()
    script.runnerStatusSequence = states.map { RunnerStatus(state: $0, pid: 4_242) }
    return script
  }

  @Test func happyPathCompletesAndDeletesTheEphemeralInstance() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.starting, .online, .busy, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(session.state == .runnerStarting)
      #expect(session.githubRunnerId == M2Harness.runnerID)
      #expect(session.jitIssuedAt != nil)
      #expect(await agent.lastRunnerSession() == session.id.rawValue)

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "job")
      #expect(terminal.failureCode == nil)
      #expect(terminal.runnerOnlineAt != nil)
      #expect(terminal.jobStartedAt != nil)
      #expect(terminal.jobFinishedAt != nil)

      // Spec §48 step 21: one job summary row, timed from the instance and session timestamps.
      let summaries = try await harness.jobSummaries()
      #expect(summaries.count == 1)
      #expect(summaries.first?.runnerSessionId == session.id)

      // Spec §48 step 22: an ephemeral instance is stopped and its directory removed.
      try await waitUntil("the ephemeral instance to be deleted") {
        try await harness.record(instance.id).state == .deleted
      }
      // A JIT runner is single-use and GitHub drops the registration itself, so the happy path
      // must not issue a DELETE.
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).isEmpty)
      #expect(harness.github.requests(.post, M2Harness.jitPath).count == 1)
      await agent.stop()
    }
  }

  @Test func theJITRequestCarriesTheProfileLabelsAndRunnerGroup() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy(runnerGroupID: 1)
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)

      let request = try #require(harness.github.requests(.post, M2Harness.jitPath).first)
      #expect(request.bodyValue("name") as? String == instance.name)
      #expect(request.bodyValue("labels") as? [String] == ["self-hosted", "linux"])
      #expect(request.bodyValue("runner_group_id") as? Int == 1)
      await agent.stop()
    }
  }

  @Test func aRunnerThatNeverComesOnlineTimesOutAndIsRemovedFromGitHub() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(runnerOnline: .milliseconds(30))
    ) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      let terminal = try await harness.awaitTerminal(session.id)

      #expect(terminal.state == .timedOut)
      #expect(terminal.failureCode == "RUNNER_ONLINE_TIMEOUT")
      // Spec §47/`docs/state_machines.md`: every non-`completed` terminal removes the runner.
      try await waitUntil("the runner to be removed from GitHub") {
        !harness.github.requests(.delete, M2Harness.runnerPath).isEmpty
      }
      // The VM is retained for diagnosis, not deleted.
      try await waitUntil("the instance to be interrupted") {
        try await harness.record(instance.id).state == .interrupted
      }
      #expect(try await harness.record(instance.id).failureCode == "RUNNER_ONLINE_TIMEOUT")
      #expect(FileManager.default.fileExists(
        atPath: harness.paths.instanceDir(instance.id).path(percentEncoded: false)))
      await agent.stop()
    }
  }

  /// Spec §48: the JIT config is requested last, so a failure here costs nothing on GitHub and
  /// there is no runner to remove.
  @Test func aFailedJITRequestEndsTheSessionAsJitFailed() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      harness.github.stub(.post, M2Harness.jitPath, .error(500, message: "server error"))
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()

      await #expect(throws: (any Error).self) {
        _ = try await harness.runners.startSession(instanceId: instance.id)
      }

      let sessions = try await harness.runners.list()
      #expect(sessions.count == 1)
      #expect(sessions.first?.state == .jitFailed)
      #expect(sessions.first?.githubRunnerId == nil)
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).isEmpty)
      try await waitUntil("the instance to be interrupted") {
        try await harness.record(instance.id).state == .interrupted
      }
      await agent.stop()
    }
  }

  /// The guest refused the spawn outright, so the registration GitHub just created is dead weight
  /// and has to go.
  @Test func aRefusedStartRunnerRemovesTheRunnerFromGitHub() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.failures[.startRunner] = RPCErrorPayload(
        code: "INTERNAL", message: "no runner user on this image")
      let (instance, agent) = try await harness.idleInstance(script: script)

      await #expect(throws: (any Error).self) {
        _ = try await harness.runners.startSession(instanceId: instance.id)
      }

      let session = try #require(try await harness.runners.list().first)
      #expect(session.state == .runnerStartFailed)
      #expect(session.githubRunnerId == M2Harness.runnerID)
      try await waitUntil("the runner to be removed from GitHub") {
        !harness.github.requests(.delete, M2Harness.runnerPath).isEmpty
      }
      await agent.stop()
    }
  }

  @Test func aLostStartRunnerReplyIsRecoveredFromTheGuestWithoutASecondStart() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = Self.script([.starting, .online, .busy, .exited])
      script.startRunnerFailsAfterStart = RPCErrorPayload(
        code: "INTERNAL", message: "the reply never made it back")
      let (instance, agent) = try await harness.idleInstance(script: script)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(session.state == .runnerStarting)

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      // `agent.startRunner` is single-shot: exactly one spawn, no blind retry.
      #expect(await agent.callCount(.startRunner) == 1)
      await agent.stop()
    }
  }

  @Test func aWorkerDisconnectDuringAJobInterruptsTheSession() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      await harness.instances.handleWorkerDisconnect(id: instance.id)

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .jobInterrupted)
      #expect(terminal.failureCode == "VM_LOST")
      try await waitUntil("the runner to be removed from GitHub") {
        !harness.github.requests(.delete, M2Harness.runnerPath).isEmpty
      }
      #expect(try await harness.record(instance.id).state == .interrupted)
      await agent.stop()
    }
  }

  /// GitHub down at teardown must not lose the removal: it becomes a durable `operations` row the
  /// maintenance loop retries (spec §119).
  @Test func aFailedRemovalIsQueuedAndRetriedLater() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(runnerOnline: .milliseconds(30))
    ) { harness in
      harness.stubGitHub()
      harness.github.stub(.delete, M2Harness.runnerPath, .error(500), .empty(204))
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)
      try await waitUntil("the removal attempt to be recorded") {
        try await harness.operations().contains { $0.kind == "remove-runner" }
      }
      let queued = try #require(
        try await harness.operations().first { $0.kind == "remove-runner" })
      #expect(queued.state == .failed)
      #expect(queued.idempotencyKey == "remove-runner:\(session.id.rawValue)")

      let retried = await harness.runners.retryPendingRemovals()

      #expect(retried == 1)
      let settled = try #require(
        try await harness.operations().first { $0.kind == "remove-runner" })
      #expect(settled.state == .succeeded)
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 2)
      _ = instance
      await agent.stop()
    }
  }

  @Test func anUnhealthyScopeRefusesTheSessionAndLeavesTheInstanceIdle() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      let (instance, agent) = try await harness.idleInstance()

      let error = await captureOrchestrationError {
        _ = try await harness.runners.startSession(instanceId: instance.id)
      }

      #expect(error?.code == "GITHUB_SCOPE_NOT_SCHEDULABLE")
      #expect(try await harness.record(instance.id).state == .idle)
      #expect(harness.github.requests(.post, M2Harness.jitPath).isEmpty)
      await agent.stop()
    }
  }

  /// Spec §77: a public repository needs an explicit opt-in, so the scope reconciler marks it
  /// unhealthy and nothing schedules there.
  @Test func aPublicRepositoryScopeIsUnhealthyAndNotSchedulable() async throws {
    try await withHarness { harness in
      harness.stubGitHub(visibility: "public", isPrivate: false)
      let (instance, agent) = try await harness.idleInstance()

      let scopes = await harness.scopeHealth.refresh()

      let scope = try #require(scopes.first)
      #expect(scope.status == "unhealthy")
      #expect(!scope.schedulable)
      #expect(scope.isPublicRepository == true)
      #expect(scope.problems.contains { $0.code == "GITHUB_PUBLIC_REPOSITORY_NOT_ALLOWED" })

      let error = await captureOrchestrationError {
        _ = try await harness.runners.startSession(instanceId: instance.id)
      }
      #expect(error?.code == "GITHUB_SCOPE_NOT_SCHEDULABLE")
      await agent.stop()
    }
  }

  @Test func anAllowedPublicRepositoryIsHealthy() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(allowPublicRepositories: true)
    ) { harness in
      harness.stubGitHub(visibility: "public", isPrivate: false)

      let scopes = await harness.scopeHealth.refresh()

      #expect(scopes.first?.status == "healthy")
      #expect(scopes.first?.schedulable == true)
      #expect(scopes.first?.runnerGroupId == 1)
    }
  }

  /// Spec §36, §128: the JIT config is a bearer-equivalent secret and must exist nowhere but in
  /// memory between `generate-jitconfig` and `agent.startRunner`.
  @Test func theJITSecretNeverReachesDisk() async throws {
    try await withHarness(onDiskDatabase: true) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      await agent.stop()

      // SQLite (plus its WAL), instance directories, spec files and logs all live under the tree.
      #expect(filesContaining(M2Harness.jitSecret, under: harness.tree.root).isEmpty)
      #expect(!"\(terminal)".contains(M2Harness.jitSecret))
    }
  }

  /// Spec §148: the debug command reuses an idle VM rather than booting one when it can.
  @Test func debugRunJITReusesAnIdleInstanceAndReportsTheSession() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      let service = harness.service()

      let response = try await service.debugRunJIT(DebugRunJITRequest(profile: "linux"))

      #expect(response.instanceId == instance.id.rawValue)
      #expect(!response.createdInstance)
      let listed = try await service.runnerList().sessions
      #expect(listed.count == 1)
      #expect(listed.first?.id == response.sessionId)
      #expect(listed.first?.profile == "linux")
      #expect(listed.first?.githubRunnerId == M2Harness.runnerID)

      try await harness.awaitTerminal(RunnerSessionID(rawValue: response.sessionId))
      let shown = try await service.runnerGet(
        RunnerGetRequest(sessionId: response.sessionId))
      #expect(shown.state == "completed")
      #expect(shown.terminal)
      #expect(shown.jobStartedAt != nil)
      await agent.stop()
    }
  }

  @Test func aSecondSessionOnTheSameInstanceIsRefused() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .online, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)

      _ = try await harness.runners.startSession(instanceId: instance.id)
      let error = await captureOrchestrationError {
        _ = try await harness.runners.startSession(instanceId: instance.id)
      }

      // The instance is no longer idle, which is the first gate a second scheduler hits.
      #expect(error?.code == "INSTANCE_NOT_IDLE")
      await agent.stop()
    }
  }
}

func captureOrchestrationError(_ body: () async throws -> Void) async -> OrchestrationError? {
  do {
    try await body()
    return nil
  } catch let error as OrchestrationError {
    return error
  } catch {
    Issue.record("expected an OrchestrationError, got \(error)")
    return nil
  }
}
