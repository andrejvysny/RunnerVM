import Foundation
import GitHubControl
import GuestControl
import ImageStore
import Persistence
import RPC
import RunnerCore
import Testing

@testable import Orchestration

/// M11: the reusable VM lifecycle. `busy -> cleaning -> idle` when the VM can still be trusted,
/// and recycling whenever it cannot (spec §9.2, §46, §72, §126, §138).
@Suite struct ReusableLifecycleTests {
  /// One answer per `agent.runnerStatus` poll, sticking on the last.
  static func script(_ states: [RunnerProcessState]) -> FakeGuestAgent.Script {
    var script = FakeGuestAgent.Script()
    script.runnerStatusSequence = states.map { RunnerStatus(state: $0, pid: 4_242) }
    return script
  }

  static func reusable(
    maxJobs: Int = 10, maxAge: DurationValue = .hours(4), recycleOnFailure: Bool = true,
    maxRestarts: Int = 1, runnerOnline: DurationValue = .minutes(2),
    allowPublicRepositories: Bool = false
  ) -> RunnerConfiguration {
    M2Harness.configuration(
      runnerOnline: runnerOnline, lifecycle: .reusable,
      allowPublicRepositories: allowPublicRepositories,
      reuse: ReusePolicy(
        maxJobs: maxJobs, maxAge: maxAge, recycleOnFailure: recycleOnFailure,
        maxRestarts: maxRestarts))
  }

  // MARK: - Happy path

  @Test func aCompletedJobCleansTheVMBackToIdleAndTheNextJobGetsTheNextEpoch() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let first = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(first.id).state == .completed)
      try await waitUntil("the VM to be cleaned back to idle") {
        try await harness.record(instance.id).state == .idle
      }

      var record = try await harness.record(instance.id)
      #expect(record.jobsConsumed == 1)
      #expect(!record.tainted)
      #expect(record.lastSeenAt != nil)
      // Spec §9.2: the cleanup epoch is the job counter, and the agent saw it exactly once.
      #expect(await agent.cleanupEpochs() == [1])
      #expect(await agent.callCount(.cleanup) == 1)

      await agent.setRunnerStatusSequence(
        [.online, .busy, .exited].map { RunnerStatus(state: $0, pid: 4_242) })
      let second = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(second.id).state == .completed)
      try await waitUntil("the VM to be cleaned back to idle a second time") {
        try await harness.record(instance.id).state == .idle
      }

      record = try await harness.record(instance.id)
      #expect(record.jobsConsumed == 2)
      #expect(await agent.cleanupEpochs() == [1, 2])
      // The whole point: one VM, two jobs, one clone.
      #expect(try await harness.instanceCount(profile: "linux") == 1)
      await agent.stop()
    }
  }

  // MARK: - Bounds (spec §126)

  @Test func theVMIsRecycledOnceItHasRunMaxJobs() async throws {
    try await withHarness(configuration: Self.reusable(maxJobs: 2)) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let first = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(first.id)
      try await waitUntil("the VM to be reused") {
        try await harness.record(instance.id).state == .idle
      }

      await agent.setRunnerStatusSequence(
        [.online, .busy, .exited].map { RunnerStatus(state: $0, pid: 4_242) })
      let second = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(second.id)

      try await waitUntil("the VM to be recycled after the last job") {
        try await harness.record(instance.id).state == .deleted
      }
      let record = try await harness.record(instance.id)
      #expect(record.jobsConsumed == 2)
      // A bound reached is retirement, not a trust problem.
      #expect(!record.tainted)
      #expect(await agent.cleanupEpochs() == [1])
      await agent.stop()
    }
  }

  @Test func theVMIsRecycledOnceItIsOlderThanMaxAge() async throws {
    let aged: @Sendable () -> Date = { Date().addingTimeInterval(3_600) }
    try await withHarness(
      configuration: Self.reusable(maxAge: .minutes(10)), now: aged
    ) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)

      try await waitUntil("the aged VM to be recycled") {
        try await harness.record(instance.id).state == .deleted
      }
      #expect(await agent.callCount(.cleanup) == 0)
      #expect(!(try await harness.record(instance.id).tainted))
      await agent.stop()
    }
  }

  @Test func aFailedSessionRecyclesTheVMWhenRecycleOnFailureIsSet() async throws {
    try await withHarness(
      configuration: Self.reusable(runnerOnline: .milliseconds(30))
    ) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(session.id).state == .timedOut)

      try await waitUntil("the VM to be recycled after the failure") {
        try await harness.record(instance.id).state == .deleted
      }
      let record = try await harness.record(instance.id)
      #expect(record.tainted)
      #expect(record.taintReason == TaintReason.sessionFailed)
      #expect(record.failureCode == "RUNNER_ONLINE_TIMEOUT")
      await agent.stop()
    }
  }

  // MARK: - Trust (spec §126)

  @Test func aFailedCleanupTaintsTheVMAndNeverReturnsItToIdle() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      await agent.fail(
        .cleanup, with: RPCErrorPayload(code: "INTERNAL", message: "rm -rf _work failed"))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(session.id).state == .completed)

      try await waitUntil("the VM to be recycled after the failed cleanup") {
        try await harness.record(instance.id).state == .deleted
      }
      let record = try await harness.record(instance.id)
      #expect(record.tainted)
      #expect(record.taintReason == TaintReason.cleanupFailed)
      await agent.stop()
    }
  }

  @Test func aRebootUnderneathUsTaintsTheVMAndRecyclesIt() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      await agent.setBootId("11111111-2222-4333-8444-555555555555")

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)

      try await waitUntil("the rebooted VM to be recycled") {
        try await harness.record(instance.id).state == .deleted
      }
      let record = try await harness.record(instance.id)
      #expect(record.tainted)
      #expect(record.taintReason == TaintReason.unexpectedReboot)
      await agent.stop()
    }
  }

  @Test func aGuestOutOfDiskIsTaintedAndRecycled() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      var metrics = FakeGuestAgent.Script.defaultMetrics
      metrics.disk = GuestMetrics.DiskMetrics(
        rootTotalBytes: 40 << 30, rootUsedBytes: 39 << 30, rootAvailableBytes: 1 << 30)
      await agent.setMetrics(metrics)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)

      try await waitUntil("the full VM to be recycled") {
        try await harness.record(instance.id).state == .deleted
      }
      #expect(try await harness.record(instance.id).taintReason == TaintReason.diskPressure)
      await agent.stop()
    }
  }

  // MARK: - Manual taint

  @Test func taintingAnIdleVMRecyclesItImmediately() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      let (instance, agent) = try await harness.idleInstance()

      let tainted = try await harness.instances.taint(id: instance.id, reason: TaintReason.manual)

      #expect(tainted.tainted)
      #expect(try await harness.record(instance.id).state == .deleted)
      await agent.stop()
    }
  }

  @Test func taintingABusyVMRetiresItWhenTheJobEnds() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      let tainted = try await harness.instances.taint(id: instance.id, reason: "OPERATOR")

      // The job keeps running: nothing may move the state of a VM under somebody's workflow.
      #expect(tainted.state == .busy)
      #expect(tainted.retireAfterSession)
      await agent.setRunnerStatus(
        RunnerStatus(state: .exited, pid: 4_242, exitCode: 0, exitedAt: nil))
      try await harness.awaitTerminal(session.id)

      try await waitUntil("the tainted VM to be recycled after its job") {
        try await harness.record(instance.id).state == .deleted
      }
      #expect(await agent.callCount(.cleanup) == 0)
      await agent.stop()
    }
  }

  @Test func aTaintedIdleVMIsNeverHandedASession() async throws {
    let config = Self.reusable()
    try await withHarness(configuration: config) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      // Marked without recycling, so the scheduler sees a tainted VM that is still `idle`.
      try await harness.instanceRows.applyReuse(
        id: instance.id, ReuseUpdate(tainted: true, taintReason: TaintReason.manual))
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()

      #expect(try await harness.runners.list().isEmpty)
      #expect(harness.github.requests(.post, M2Harness.jitPath).isEmpty)
      #expect(try await harness.record(instance.id).state == .deleted)
      await agent.stop()
    }
  }

  // MARK: - Image updates (spec §138)

  @Test func aProfileImageUpdateRetiresTheIdleReusableVMsOnTheOldDigest() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      let (instance, agent) = try await harness.idleInstance()
      let disk = try harness.sparseFile(named: "linux-v2.img", bytes: 48 << 20)
      _ = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "test-linux-v2")
      var next = ReusableLifecycleTests.reusable()
      next.profiles[0].image = "test-linux-v2"
      _ = try await GRDBConfigStore(db: harness.database).apply(next, actor: "test")

      let marked = await harness.instances.retireOutdatedReusable()

      #expect(marked == 1)
      #expect(try await harness.record(instance.id).retireAfterSession)
      // Spec §138: the running instance keeps the digest it booted from.
      let running = try await harness.record(instance.id).imageDigest
      #expect(running != (try await harness.images.resolve(reference: "test-linux-v2")))

      // The orchestrator takes it away on the next pass so a fresh one can replace it.
      let manual = ManualDemandProvider()
      let orchestrator = await harness.orchestrator(demand: manual, configuration: next)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.record(instance.id).state == .deleted)
      await agent.stop()
    }
  }

  /// `imageUpdates.recycleReusable: false` is the operator's opt-out (spec §138): a superseded
  /// digest no longer retires anything, reusable or not.
  @Test func imageUpdatesRecycleReusableFalseSkipsRetirement() async throws {
    var config = ReusableLifecycleTests.reusable()
    config.imageUpdates = ImageUpdatesConfig(recycleReusable: false)
    try await withHarness(configuration: config) { harness in
      let (instance, agent) = try await harness.idleInstance()
      let disk = try harness.sparseFile(named: "linux-v2.img", bytes: 48 << 20)
      _ = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "test-linux-v2")
      var next = config
      next.profiles[0].image = "test-linux-v2"
      _ = try await GRDBConfigStore(db: harness.database).apply(next, actor: "test")

      let marked = await harness.instances.retireOutdatedReusable()

      #expect(marked == 0)
      #expect(!(try await harness.record(instance.id).retireAfterSession))
      await agent.stop()
    }
  }

  // MARK: - Worker crash recovery (spec §72)

  @Test func anIdleReusableVMSurvivesOneWorkerDeathAndIsRecycledOnTheSecond() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      let (instance, agent) = try await harness.idleInstance()
      #expect(try await harness.record(instance.id).workerGeneration == 1)

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)

      try await waitUntil("the restarted VM to reach idle again") {
        try await harness.record(instance.id).state == .idle
      }
      #expect(try await harness.record(instance.id).workerGeneration == 2)

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)

      try await waitUntil("the VM to be recycled after a second worker death") {
        try await harness.record(instance.id).state == .deleted
      }
      await agent.stop()
    }
  }

  /// `reuse.maxRestarts` is now the profile's own budget, not the old hard-coded constant of 1
  /// (spec §72).
  @Test func aReusableVMWithACustomMaxRestartsSurvivesMoreWorkerDeaths() async throws {
    try await withHarness(configuration: Self.reusable(maxRestarts: 2)) { harness in
      let (instance, agent) = try await harness.idleInstance()
      #expect(try await harness.record(instance.id).workerGeneration == 1)

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)
      try await waitUntil("the first restart to reach idle again") {
        try await harness.record(instance.id).state == .idle
      }
      #expect(try await harness.record(instance.id).workerGeneration == 2)

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)
      try await waitUntil("the second restart to reach idle again") {
        try await harness.record(instance.id).state == .idle
      }
      #expect(try await harness.record(instance.id).workerGeneration == 3)

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)
      try await waitUntil("the VM to be recycled after exceeding maxRestarts") {
        try await harness.record(instance.id).state == .deleted
      }
      await agent.stop()
    }
  }

  @Test func anEphemeralVMIsNeverRestartedAfterItsWorkerDies() async throws {
    try await withHarness { harness in
      let (instance, agent) = try await harness.idleInstance()

      await harness.launcher.killWorker(instance.id)
      await harness.instances.markWorkerDead(id: instance.id)

      #expect(try await harness.record(instance.id).state == .interrupted)
      #expect(try await harness.record(instance.id).workerGeneration == 1)
      await agent.stop()
    }
  }

  /// A daemon restart leaves nobody to finish a cleanup, and an unfinished cleanup can never be
  /// called clean (spec §126).
  @Test func aVMAbandonedInCleaningIsRecycledOnTheNextReconcile() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      let (instance, agent) = try await harness.idleInstance()
      // The state a crash between `busy -> cleaning` and `cleaning -> idle` leaves behind.
      _ = try await harness.instanceRows.transition(
        id: instance.id, from: .idle, to: .configuringRunner, expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: instance.id, from: .configuringRunner, to: .runnerStarting,
        expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: instance.id, from: .runnerStarting, to: .runnerOnline, expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: instance.id, from: .runnerOnline, to: .busy, expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: instance.id, from: .busy, to: .cleaning, expectedGeneration: nil) { _ in }

      await harness.instances.recheckAgents()

      try await waitUntil("the abandoned VM to be recycled") {
        try await harness.record(instance.id).state == .deleted
      }
      #expect(try await harness.record(instance.id).taintReason == TaintReason.cleanupFailed)
      await agent.stop()
    }
  }

  // MARK: - Policy

  /// Spec §9.2: reuse is documented as weaker isolation, so it is off for a public repository
  /// even when the operator has opted into scheduling there at all.
  @Test func aPublicRepositoryScopeFallsBackToEphemeralBehaviour() async throws {
    try await withHarness(
      configuration: Self.reusable(allowPublicRepositories: true)
    ) { harness in
      harness.stubGitHub(visibility: "public", isPrivate: false)
      await harness.scopeHealth.refresh()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(session.id).state == .completed)

      try await waitUntil("the VM to be retired rather than reused") {
        try await harness.record(instance.id).state == .deleted
      }
      #expect(await agent.callCount(.cleanup) == 0)
      #expect(try await harness.record(instance.id).jobsConsumed == 1)
      await agent.stop()
    }
  }

  // MARK: - Decision table

  @Test func theReuseVerdictImplementsTheSafeguardList() throws {
    let policy = ReusePolicy(maxJobs: 2, maxAge: .minutes(10), recycleOnFailure: true)
    let now = Date()
    let ok = SessionOutcome(completed: true, detail: "")

    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now), policy: policy, outcome: ok, now: now) == nil)
    #expect(InstanceManager.verdict(
      Self.row(jobs: 2, createdAt: now), policy: policy, outcome: ok, now: now)?.reason
      == "max-jobs")
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now.addingTimeInterval(-1_800)), policy: policy, outcome: ok,
      now: now)?.reason == "max-age")
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now, tainted: true), policy: policy, outcome: ok,
      now: now)?.reason == "tainted")
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now, retire: true), policy: policy, outcome: ok,
      now: now)?.reason == "retire-after-session")
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now), policy: policy,
      outcome: SessionOutcome(completed: true, detail: "", publicRepositoryScope: true),
      now: now)?.reason == "public-repository")
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now), policy: policy,
      outcome: SessionOutcome(completed: false, detail: ""), now: now)?.taint
      == TaintReason.sessionFailed)
    // `recycleOnFailure: false` keeps the VM: the cleanup itself is then the only gate.
    #expect(InstanceManager.verdict(
      Self.row(jobs: 1, createdAt: now), policy: ReusePolicy(recycleOnFailure: false),
      outcome: SessionOutcome(completed: false, detail: ""), now: now) == nil)
  }

  @Test func theDiskHeadroomGateFiresBelowATenthOfTheRoot() throws {
    var metrics = FakeGuestAgent.Script.defaultMetrics
    metrics.disk = GuestMetrics.DiskMetrics(
      rootTotalBytes: 100, rootUsedBytes: 89, rootAvailableBytes: 11)
    #expect(throws: Never.self) { try InstanceManager.assertDiskHeadroom(metrics) }

    metrics.disk = GuestMetrics.DiskMetrics(
      rootTotalBytes: 100, rootUsedBytes: 91, rootAvailableBytes: 9)
    #expect(throws: ReuseFailure.self) { try InstanceManager.assertDiskHeadroom(metrics) }
    #expect(InstanceManager.taint(for: ReuseFailure.diskPressure(
      availableBytes: 9, totalBytes: 100)) == TaintReason.diskPressure)
    #expect(InstanceManager.taint(for: GuestAgentError.bootIDChanged(previous: "a", current: "b"))
      == TaintReason.unexpectedReboot)
    #expect(InstanceManager.taint(for: GuestAgentError.unhealthy(reason: "docker"))
      == TaintReason.agentDegraded)
  }

  private static func row(
    jobs: Int, createdAt: Date, tainted: Bool = false, retire: Bool = false
  ) -> InstanceRecord {
    InstanceRecord(
      id: .generate(), profileId: RunnerProfileID(rawValue: "p"),
      imageDigest: ImageDigest(rawValue: "sha256:" + String(repeating: "a", count: 64)),
      hostId: HostID(rawValue: "h"), name: "rvm-test", lifecycle: .reusable, state: .busy,
      desiredState: .idle, cpuCount: 2, memoryBytes: 1 << 30, diskBytes: 1 << 30,
      diskReservationBytes: 1 << 30, tainted: tainted, jobsConsumed: jobs,
      retireAfterSession: retire, instancePath: "/tmp/x",
      createdAt: DatabaseDate(createdAt))
  }
}
