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
