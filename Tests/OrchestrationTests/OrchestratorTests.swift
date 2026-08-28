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
      #expect(try await harness.record(started.id).state != .deleted)

      await demand.setConfirmed(true)
      await orchestrator.tick()
      #expect(try await harness.record(started.id).state == .deleted)
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
