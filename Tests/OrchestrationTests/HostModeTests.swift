import DaemonAPI
import Foundation
import GuestControl
import Metrics
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// M13 host mode control (spec §108, §109): draining advertises nothing and admits nothing, while
/// the jobs already on the host run to the end.
@Suite struct HostModeTests {
  private func control(_ harness: M2Harness) -> HostModeControl {
    HostModeControl(
      hostId: harness.hostId, hosts: harness.hosts, sessions: harness.sessionRows,
      audit: GRDBAuditRepository(db: harness.database), actorName: "test")
  }

  @Test func drainStopsAdvertisingAndStartingWhileResumeRestoresBoth() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)
      let mode = control(harness)

      #expect(try await mode.drain().mode == .draining)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(await manual.advertisedCapacity(profile: profile) == 0)
      #expect(try await harness.instanceCount(profile: "linux") == 0)

      #expect(try await mode.resume().mode == .normal)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(await manual.advertisedCapacity(profile: profile) == 2)
      #expect(try await harness.instanceCount(profile: "linux") == 2)
    }
  }

  /// The point of §109: a drain is not a kill. The session that was already running finishes, and
  /// only then does the host report itself idle.
  @Test func drainingLetsAnActiveSessionFinish() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatusSequence = [.starting, .online, .busy, .busy, .exited]
        .map { RunnerStatus(state: $0, pid: 4_242) }
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      let mode = control(harness)

      let drained = try await mode.drain()
      #expect(drained.mode == .draining)
      #expect(drained.activeSessions == 1)

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(await mode.activeSessions() == 0)
      // Draining never moves the host on by itself; offline is an explicit second step.
      #expect(try await mode.mode() == .draining)
      await agent.stop()
    }
  }

  @Test func offlineDrainsFirstWhenTheHostWasStillNormal() async throws {
    try await withHarness { harness in
      let mode = control(harness)

      let offline = try await mode.offline()
      let persisted = try await harness.hosts.mode(id: harness.hostId)
      #expect(offline.mode == .offline)
      #expect(persisted == .offline)
      // `offline -> normal` is the only way back, and it is one hop.
      let resumed = try await mode.resume()
      #expect(resumed.mode == .normal)
    }
  }

  @Test func drainingAnOfflineHostIsRefused() async throws {
    try await withHarness { harness in
      let mode = control(harness)
      _ = try await mode.offline()

      await #expect(throws: DaemonServiceError.self) { _ = try await mode.drain() }
    }
  }

  /// Found live: `runnerctl system drain --wait` exits on `drained`, and an idle host reported
  /// `false`, so the operator's drain "failed" while the host had in fact stopped admitting.
  @Test func drainingAnIdleHostReportsItDrained() async throws {
    try await withHarness { harness in
      let mode = control(harness)
      let report = try await mode.drain()
      #expect(report.mode == .draining)
      #expect(report.activeSessions == 0)
      #expect(report.drained)
      // Idempotent: a second drain of the same idle host says the same thing.
      #expect(try await mode.drain().drained)
    }
  }

  @Test func waitForIdleReturnsImmediatelyWithNoSessions() async throws {
    try await withHarness { harness in
      let mode = control(harness)
      _ = try await mode.drain()

      let report = await mode.waitForIdle(timeout: .seconds(30))

      #expect(report.drained)
      #expect(report.activeSessions == 0)
    }
  }

  // MARK: - Through the daemon service

  @Test func systemDrainAndResumeRoundTripThroughTheService() async throws {
    try await withHarness { harness in
      let service = harness.service()

      let drained = try await service.systemDrain(SystemDrainRequest())
      #expect(drained.mode == "draining")
      #expect(try await service.status().daemon.mode == "draining")

      let offline = try await service.systemOffline()
      #expect(offline.mode == "offline")

      let resumed = try await service.systemResume()
      #expect(resumed.mode == "normal")
      #expect(try await service.status().daemon.mode == "normal")
    }
  }

  /// Spec §108: a drain that still has work in flight refuses a non-forced shutdown rather than
  /// interrupting the job.
  @Test func shutdownWithoutForceRefusesWhileASessionIsActive() async throws {
    try await withHarness { harness in
      try await harness.seedInstanceAndSession()
      let service = harness.service()
      await service.setShutdownHandler { _ in }

      await #expect(throws: DaemonServiceError.self) {
        _ = try await service.systemShutdown(SystemShutdownRequest(force: false, timeoutMs: 0))
      }
    }
  }

  @Test func shutdownWithoutAHandlerReportsItselfUnavailable() async throws {
    try await withHarness { harness in
      let service = harness.service()

      await #expect(throws: DaemonServiceError.self) {
        _ = try await service.systemShutdown(SystemShutdownRequest())
      }
    }
  }
}

extension M2Harness {
  /// A capacity-consuming instance with a live session bound to it, without booting a guest.
  func seedInstanceAndSession() async throws {
    let digest = try await importLinuxImage().record.digest
    try await seedInstance(profile: "linux", state: .busy, digest: digest)
    let profile = try await profileID("linux")
    let instance = try #require(
      try await instanceRows.list(profile: profile, states: [.busy]).first)
    _ = try await seedSession(instance: instance.id, profile: "linux")
  }
}
