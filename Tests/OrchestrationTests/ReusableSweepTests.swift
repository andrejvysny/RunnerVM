import Foundation
import ImageStore
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// D1: the retention sweep reaps every terminal-but-not-`deleted` row, not just the ephemeral ones.
///
/// A reusable VM's restart eligibility is decided synchronously from the *predecessor* state and is
/// never persisted, so a `failed`/`interrupted`/`stopped` row a sweep can see has already lost its
/// restart whatever its lifecycle. Before this, such a row held its cpu, memory, disk reservation,
/// image pin and directory for the life of the daemon.
@Suite struct ReusableSweepTests {
  /// Retention is zero unless a case is about the window itself: what these tests are pinning is
  /// *which* rows are eligible, not how long a row waits.
  private static func reusable(retention: DurationValue = .zero) -> RunnerConfiguration {
    var config = ReusableLifecycleTests.reusable()
    config.diagnostics = DiagnosticsConfig(failedInstanceRetention: retention)
    return config
  }

  private static func ephemeral(retention: DurationValue = .zero) -> RunnerConfiguration {
    var config = M2Harness.configuration()
    config.diagnostics = DiagnosticsConfig(failedInstanceRetention: retention)
    return config
  }

  private static let failure = VMError.workerUnresponsive(reason: "test")

  // MARK: - Rows that used to be immortal

  @Test func aReusableVMThatNeverReachedIdleIsSweptOnceItFails() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      try await harness.importLinuxImage()
      // No guest agent ever answers, so this VM never reaches `idle` and is therefore never
      // eligible for a restart: exactly the row the ephemeral-only sweep left on the host forever.
      let record = try await harness.instances.create(profileName: "linux")
      await harness.instances.fail(record, phase: "agent", error: Self.failure)

      let failed = try await harness.record(record.id)
      #expect(failed.state == .failed)
      #expect(failed.lifecycle == .reusable)
      // The retention marker is the failure time. Without this stamp the sweep would judge the row
      // on `createdAt` and reap a VM that failed minutes into a long boot far too early.
      #expect(failed.stoppedAt != nil)

      let counts = try await harness.instanceReconciler().run(firstTick: false)

      #expect(counts.swept == 1)
      #expect(try await harness.record(record.id).state == .deleted)
    }
  }

  /// The other half of the gap: a daemon that died between `stop` and `delete` leaves a reusable
  /// row in `stopped`, and nothing ever walks `stopped -> startingWorker`.
  @Test func aReusableVMLeftStoppedByACrashIsSwept() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let stopped = try await harness.instances.stop(id: record.id, force: false)
      #expect(stopped.state == .stopped)

      let counts = try await harness.instanceReconciler().run(firstTick: false)

      #expect(counts.swept == 1)
      #expect(try await harness.record(record.id).state == .deleted)
    }
  }

  // MARK: - Rows the sweep must not touch

  /// The one exception the lifecycle rule needs: a restart that has been decided but has not yet
  /// claimed its row. `respawn` owns the id for the whole attempt, and the sweep asks before it
  /// commits — otherwise a tick landing in that window deletes the disk the restart is booting.
  @Test func aRespawnInFlightOwnsItsRowAndNoSweepMayTakeIt() async throws {
    try await withHarness(configuration: Self.reusable()) { harness in
      let (instance, agent) = try await harness.idleInstance()
      // The replacement worker is held at its launch, so the respawn stays inside
      // `WorkerSupervisor.start` for as long as this test needs: the window a reconcile tick can
      // land in, without a sleep to size it.
      await harness.launcher.closeLaunchGate()
      await harness.launcher.killWorker(instance.id)
      let manager = harness.instances
      let id = instance.id
      let restart = Task { await manager.markWorkerDead(id: id) }
      do {
        try await harness.awaitInstance(id, state: .startingWorker)
        #expect(await manager.isRestarting(id))
        // Put the row back where the reaper can see it. The respawn still owns it, and that
        // ownership — not the row's state — is the only thing between this VM and a delete.
        try await harness.forceInstanceState(id, to: .interrupted)

        // The exact call the sweep commits through refuses it outright...
        #expect(
          try await manager.delete(id: id, expectedState: .interrupted)
            == .skipped(state: .interrupted))
        // ...so the sweep takes nothing, and the restart still has its disk.
        let counts = try await harness.instanceReconciler().run(firstTick: false)
        #expect(counts.swept == 0)
        #expect(try await harness.record(id).state == .interrupted)
      } catch {
        // Never leave `launch` parked, on any path: a parked continuation is not cancellable, so
        // the suite would hang here instead of failing.
        await harness.launcher.openLaunchGate()
        await restart.value
        await agent.stop()
        throw error
      }
      // Letting it through: the boot CAS now fails against the row this test moved, so the respawn
      // gives up and tears the VM down itself — which is what releases the claim.
      await harness.launcher.openLaunchGate()
      try await withHangGuard("the respawn to give up") { await restart.value }
      try await harness.awaitInstance(id, state: .deleted)
      try await waitUntil("the restart claim to be released") { await !manager.isRestarting(id) }
      await agent.stop()
    }
  }

  /// A pinned VM is invisible to every reaper but its own: the operator asked for it to be here,
  /// and `MaintenanceInstanceReaper` is the only thing allowed to take it back.
  @Test func aPinnedMaintenanceRowIsNotSweptBeforeItsTTL() async throws {
    try await withHarness(configuration: Self.ephemeral()) { harness in
      try await harness.importLinuxImage()
      let deadline = Date().addingTimeInterval(600)
      let pinned = try await harness.instances.create(
        profileName: "linux",
        options: InstanceCreateOptions(purpose: .maintenance, pinnedUntil: deadline))
      await harness.instances.fail(pinned, phase: "agent", error: Self.failure)
      #expect(try await harness.record(pinned.id).state == .failed)

      // Retention has passed — it is zero — but the pin has not.
      #expect(try await harness.instanceReconciler().run(firstTick: false).swept == 0)
      #expect(try await harness.record(pinned.id).state == .failed)

      let expired = harness.instanceReconciler(now: { deadline.addingTimeInterval(1) })
      #expect(try await expired.run(firstTick: false).swept == 1)
      #expect(try await harness.record(pinned.id).state == .deleted)
    }
  }

  @Test func anEphemeralRowInsideItsRetentionWindowIsNotSwept() async throws {
    try await withHarness(configuration: Self.ephemeral(retention: .hours(2))) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.instances.fail(record, phase: "agent", error: Self.failure)

      let counts = try await harness.instanceReconciler().run(firstTick: false)

      #expect(counts.swept == 0)
      #expect(try await harness.record(record.id).state == .failed)
    }
  }

  /// The window is measured from `stopped_at` — the stamp `fail` writes — and not from
  /// `created_at`, so a VM that failed late in a long boot gets its full window.
  @Test func theRetentionWindowIsMeasuredFromTheStoppedAtMarker() async throws {
    try await withHarness(configuration: Self.ephemeral(retention: .hours(2))) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.instances.fail(record, phase: "agent", error: Self.failure)
      #expect(try await harness.instanceReconciler().run(firstTick: false).swept == 0)

      // Three hours ago: past a two-hour window, while `created_at` stays where it is.
      try await harness.forceInstanceColumn(
        record.id, "stopped_at", DatabaseDate(Date().addingTimeInterval(-10_800)))

      #expect(try await harness.instanceReconciler().run(firstTick: false).swept == 1)
      #expect(try await harness.record(record.id).state == .deleted)
    }
  }

  /// Spec §74: the retention window exists so an operator can read why a VM died. The sweep must
  /// not shorten it, and when it does fire the evidence has to survive the directory.
  @Test func theFailureRecordSurvivesUntilRetentionHasPassed() async throws {
    try await withHarness(configuration: Self.ephemeral(retention: .hours(2))) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.instances.fail(record, phase: "agent", error: Self.failure)
      #expect(
        try await harness.instanceStore.failureRecord(instanceId: record.id)?.code
          == Self.failure.code)

      #expect(try await harness.instanceReconciler().run(firstTick: false).swept == 0)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) != nil)

      let expired = harness.instanceReconciler(now: { Date().addingTimeInterval(7_300) })
      #expect(try await expired.run(firstTick: false).swept == 1)

      // The row is gone and so is its directory, but `failure.json` moved to `logs/instances/<id>/`
      // where the logging retention -- not this one -- decides how long it stays.
      #expect(try await harness.record(record.id).state == .deleted)
      let preserved = harness.paths.instanceLogDir(record.id)
        .appending(path: VMInstanceLayout.failureName)
      #expect(FileManager.default.fileExists(atPath: preserved.path(percentEncoded: false)))
    }
  }

  // MARK: - Committing on the judged state

  /// Everything between the sweep's `list` and its delete is a suspension point, so the delete has
  /// to commit against the state the sweep judged. A mismatch is not an error: whoever moved the
  /// row owns it now.
  @Test func aDeleteCommittedOnTheWrongStateSkipsInsteadOfTearingTheRowDown() async throws {
    try await withHarness(configuration: Self.ephemeral()) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      #expect(
        try await harness.instances.delete(id: record.id, expectedState: .failed)
          == .skipped(state: .waitingForAgent))
      #expect(try await harness.record(record.id).state == .waitingForAgent)

      await harness.instances.fail(record, phase: "agent", error: Self.failure)
      #expect(
        try await harness.instances.delete(id: record.id, expectedState: .interrupted)
          == .skipped(state: .failed))
      #expect(try await harness.record(record.id).state == .failed)

      guard case .deleted = try await harness.instances.delete(
        id: record.id, expectedState: .failed)
      else {
        Issue.record("the delete did not commit on the state it was given")
        return
      }
      #expect(try await harness.record(record.id).state == .deleted)
    }
  }
}
