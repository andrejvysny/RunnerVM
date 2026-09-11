import Foundation
import GitHubControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// M6/M7/M10: demand in, VMs and runner sessions out. Every test drives `tick()` by hand — the
/// reconcile loop's timing is `DaemonRuntimeTests`' business, not the scheduler's.
@Suite struct OrchestratorTests {
  @Test func demandBeyondCapacityStartsOnlyWhatFits() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 3)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()

      #expect(try await harness.instanceCount(profile: "linux") == 2)
      #expect(await manual.advertisedCapacity(profile: profile) == 2)

      // The third job stays queued: the profile is at its ceiling, so nothing more is admitted.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceCount(profile: "linux") == 2)
      #expect(await manual.advertisedCapacity(profile: profile) == 2)
    }
  }

  @Test func demandDropCancelsUnboundInstancesAndKeepsBoundOnes() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      let records = try await harness.instanceRows.list(profile: profile, states: nil)
      #expect(records.count == 2)
      let kept = try #require(records.first)
      try await harness.seedSession(instance: kept.id, profile: "linux")

      await manual.set(profile: profile, assignedJobs: 0)
      await orchestrator.tick()
      await orchestrator.drainCancels()

      let live = try await harness.instanceRows.list(profile: profile, states: nil)
        .filter { $0.state != .deleted }
      #expect(live.map(\.id) == [kept.id])
    }
  }

  /// Seen live: right after a restart the registration reply said `assignedJobs: 0`, the first
  /// pass cancelled the idle VM as surplus, and half a second later the message session reported
  /// the job that VM had been booted for. An unconfirmed figure may start VMs, never take one away.
  @Test func anUnconfirmedDemandFigureNeverCancelsAnInstance() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let demand = ConfirmationGatedDemand(manual)
      let orchestrator = await harness.orchestrator(demand: demand, configuration: config)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      let started = try #require(try await harness.instanceRows.list(profile: profile, states: nil).first)

      await manual.set(profile: profile, assignedJobs: 0)
      await demand.setConfirmed(false)
      await orchestrator.tick()
      await orchestrator.drainCancels()
      #expect(try await harness.record(started.id).state != .deleted)

      await demand.setConfirmed(true)
      await orchestrator.tick()
      await orchestrator.drainCancels()
      #expect(try await harness.record(started.id).state == .deleted)
    }
  }

  /// A cancel walks the whole teardown ladder -- `worker.shutdown`, the profile's grace window,
  /// then the worker's exit -- so it runs detached like a start does: a tick that waited for one
  /// would stall the 10 s reconcile loop, worker recovery included. The wedge here is a worker
  /// that answers `worker.shutdown` and then keeps its lock, which is what a slow guest looks like.
  @Test func aCancelThatCannotFinishNeverStallsTheNextTick() async throws {
    try await withHarness { harness in
      let (instance, agent) = try await harness.idleInstance()
      await harness.launcher.worker(for: instance.id)?.setExitHandler {}
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual)

      // Well inside the wedge: the exit wait alone runs for seconds, so a tick that waited for
      // the teardown fails here rather than merely being slow.
      try await withHangGuard(
        "two ticks while a cancel is still tearing a VM down", limit: .seconds(5)) {
        await orchestrator.tick()
        await orchestrator.tick()
      }

      // Still going: the row cannot reach `deleted` while its worker holds the lock.
      #expect(try await harness.record(instance.id).state != .deleted)

      // Unwedge, and the detached delete finishes on its own.
      await harness.launcher.killWorker(instance.id)
      await orchestrator.drainCancels()
      #expect(try await harness.record(instance.id).state == .deleted)
      await agent.stop()
    }
  }

  @Test func idleInstanceWithDemandGetsAScaleSetJITSession() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (record, agent) = try await harness.idleInstance()
      try await harness.registerScaleSet(profile: "linux", githubScaleSetId: 777)
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()

      let calls = harness.scaleSetPlane.jitCalls()
      #expect(calls.count == 1)
      #expect(calls.first?.scaleSetID == 777)
      #expect(calls.first?.runnerName == record.name)
      let sessions = try await harness.runners.list()
      #expect(sessions.count == 1)
      #expect(sessions.first?.jitSource == .scaleSet)
      #expect(sessions.first?.instanceId == record.id)

      // A second pass must not hand the same instance a second registration.
      await orchestrator.tick()
      #expect(harness.scaleSetPlane.jitCalls().count == 1)
      #expect(try await harness.runners.list().count == 1)
      await agent.stop()
    }
  }

  @Test func drainingAdvertisesZeroAndStartsNothing() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      try await harness.hosts.setMode(id: harness.hostId, from: .normal, to: .draining)
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainStarts()

      #expect(await manual.advertisedCapacity(profile: profile) == 0)
      #expect(try await harness.instanceCount(profile: "linux") == 0)
    }
  }

  @Test func macOSGuestLimitBoundsOneProfileWithoutBlockingAnother() async throws {
    try await withHarness { harness in
      let linux = try await harness.importLinuxImage()
      try await harness.importMacImage()
      for _ in 0..<2 {
        try await harness.seedInstance(
          profile: "mac", state: .waitingForAgent, digest: linux.record.digest)
      }
      let mac = try await harness.profileID("mac")
      let linuxProfile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: mac, assignedJobs: 3)
      await manual.set(profile: linuxProfile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainStarts()

      #expect(try await harness.instanceCount(profile: "mac") == 2)
      #expect(await manual.advertisedCapacity(profile: mac) == 2)
      #expect(try await harness.instanceCount(profile: "linux") == 1)
    }
  }

  @Test func aFailedStartHoldsTheProfileDownBeforeRetrying() async throws {
    try await withHarness { harness in
      // No image imported: `create` fails while resolving the profile's image reference.
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      let afterFirst = await orchestrator.recentEvents()
        .count { if case .instanceStartFailed = $0.event { true } else { false } }
      #expect(afterFirst == 1)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      let afterSecond = await orchestrator.recentEvents()
        .count { if case .instanceStartFailed = $0.event { true } else { false } }
      #expect(afterSecond == 1)
      #expect(try await harness.instanceCount(profile: "linux") == 0)
    }
  }

  /// A boot that fails does not throw out of `create`: the ladder reports it by leaving the row in
  /// a failed state. Without the hold-down that covers it, a permanently unbootable image (a macOS
  /// hardware model this host cannot run, say) would be cloned and booted again on every single
  /// tick -- a full disk clone and a dead VM per tick, forever.
  @Test func anInstanceThatFailsToBootAlsoHoldsTheProfileDown() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = [.error]
      await harness.launcher.set(behaviour)
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      let afterFirst = await orchestrator.recentEvents()
        .count { if case .instanceStartFailed = $0.event { true } else { false } }
      #expect(afterFirst == 1)

      // The second tick must not start anything: the profile is held down, so the count of both
      // failures and instances stays where it was.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      let afterSecond = await orchestrator.recentEvents()
        .count { if case .instanceStartFailed = $0.event { true } else { false } }
      #expect(afterSecond == 1)
      #expect(try await harness.instanceCount(profile: "linux") == 1)
    }
  }

  /// The same protection for the boot half of the ladder, which lands after `create` has already
  /// returned: `timeouts.vmBoot` expires on a watcher, not inside the start task, so what keeps the
  /// next tick from cloning and booting the same unbootable image again is the failed row itself --
  /// it holds the profile's reservation until the reaper takes it, and the demand it was started
  /// for stays accounted for.
  @Test func aBootTimeoutHoldsTheProfileDown() async throws {
    // Well above the create ladder: the budget starts at `cloning`, and a ladder that overran it
    // under load would report the timeout against a different phase.
    let config = M2Harness.configuration(vmBoot: .seconds(3))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      // A worker that acknowledges `vm.start` and then never reports the guest running.
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      let started = try #require(
        try await harness.instanceRows.list(profile: profile, states: nil).first)
      let failed = try await harness.awaitInstance(started.id, state: .failed)
      #expect(failed.failureCode == "VM_BOOT_TIMEOUT")

      // The second tick must not clone and boot the same broken image again: a full disk clone and
      // a dead VM per tick is exactly what this bounds.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceCount(profile: "linux") == 1)
      #expect(try await harness.record(started.id).state == .failed)
    }
  }

  @Test func warmPoolKeepsOneIdleInstanceWithoutASession() async throws {
    let config = M2Harness.configuration(warmPool: WarmPoolPolicy(minIdle: 1, maxIdle: 1))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceCount(profile: "linux") == 1)

      let record = try #require(
        try await harness.instanceRows.list(profile: profile, states: nil).first)
      let agent = try await harness.startGuestAgent(for: record.id)
      try await waitUntil("the warm instance to reach idle") {
        try await harness.record(record.id).state == .idle
      }

      // Idle with no demand: the warm VM is kept and never handed a runner session.
      await orchestrator.tick()
      #expect(try await harness.record(record.id).state == .idle)
      #expect(try await harness.runners.list().isEmpty)
      #expect(try await harness.instanceCount(profile: "linux") == 1)
      await agent.stop()
    }
  }

  /// A JIT deadline destroys the VM it failed on (nothing is wrong with the guest), so with demand
  /// still standing the next tick would clone and boot a replacement, hand it to the same
  /// unreachable GitHub, and destroy that one too -- a VM per tick for the length of the outage.
  /// The hold-down the VM-start path already uses governs the retry cadence instead.
  @Test func aGitHubFailureDuringHandOffHoldsTheProfileDownLikeAFailedStart() async throws {
    let config = M2Harness.configuration(jitGeneration: .milliseconds(50))
    try await withHarness(configuration: config) { harness in
      harness.stubGitHub()
      // Reachable, never answers: the shape that expires the JIT deadline.
      harness.github.stub(.post, M2Harness.jitPath, .json("{}", delay: .seconds(10)))
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let clock = TestClock()
      let orchestrator = await harness.orchestrator(
        demand: manual, configuration: config, now: { clock.now })

      // Tick 1 needs no new VM (the idle one covers the demand); it hands that one off, the JIT
      // deadline expires, and the VM is destroyed.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      try await harness.awaitInstance(instance.id, state: .deleted)
      let afterFailure = try await harness.instanceRows.list(profile: profile, states: nil).count
      #expect(afterFailure == 1)

      // Tick 2: demand is still standing and there is no VM left to serve it, but the profile is
      // held down, so nothing is cloned or booted.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceRows.list(profile: profile, states: nil).count == 1)

      // Once the window passes the profile is startable again -- held down, not switched off.
      clock.advance(by: Double(Orchestrator.Tuning().startHoldDown.components.seconds) + 1)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(try await harness.instanceRows.list(profile: profile, states: nil).count == 2)
      await agent.stop()
    }
  }
}

/// Wraps `ManualDemandProvider` and lets a test flip `DemandSnapshot.confirmed`, which is what a
/// scale-set registration reply looks like before its message session has spoken.
actor ConfirmationGatedDemand: DemandProvider {
  private let inner: ManualDemandProvider
  private var confirmed = true

  init(_ inner: ManualDemandProvider) { self.inner = inner }

  func setConfirmed(_ value: Bool) { confirmed = value }

  func start() async throws { try await inner.start() }
  func stop() async { await inner.stop() }
  var events: AsyncStream<DemandEvent> { get async { await inner.events } }

  func snapshot(profile: RunnerProfileID) async -> DemandSnapshot {
    var snapshot = await inner.snapshot(profile: profile)
    snapshot.confirmed = confirmed
    return snapshot
  }

  func advertise(profile: RunnerProfileID, capacity: Int) async {
    await inner.advertise(profile: profile, capacity: capacity)
  }

  func refresh() async { await inner.refresh() }
  func report() async -> [DemandProviderReport] { await inner.report() }

}
