import Foundation
import Metrics
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// D5, D5b and D9: the three ways a row could stop moving without anything noticing.
///
/// Together with the retention sweep (`ReusableSweepTests`) these close the invariant that no
/// instance row stays non-`deleted` indefinitely without being retried or reaped, and that both
/// are counted.
@Suite struct StuckDeleteTests {
  private static func linuxImageRow(state: ImageState) -> ImageRecord {
    ImageRecord(
      digest: ImageDigest(rawValue: "sha256:" + String(repeating: "c", count: 64)),
      canonicalReference: "registry.test/acme/linux@sha256:" + String(repeating: "c", count: 64),
      os: .linux, architecture: "arm64", schemaVersion: 1, metadataJson: "{}",
      localPath: "/nonexistent/staging", virtualSizeBytes: 1 << 20, state: state, createdAt: .now)
  }

  // MARK: - D5: a delete that never finished

  @Test func aRowStuckInDeletingIsRetriedOnceTheGraceHasPassed() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      // What a `delete` that threw with the row already committed leaves behind: no `deleting_at`
      // column, no owner, and nothing that would ever look at it again.
      try await harness.forceInstanceState(record.id, to: .deleting)

      let clock = TestClock()
      let reconciler = harness.instanceReconciler(now: { clock.now })

      // The tick that first sees the row never retries it: an ordinary teardown sits in `deleting`
      // for as long as the guest's graceful shutdown takes.
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)
      #expect(try await harness.record(record.id).state == .deleting)

      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)

      try await harness.awaitInstance(record.id, state: .deleted)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.instanceDeleteRetriesTotal, labels: ["profile": "linux"]) == 1)
    }
  }

  /// The retry exists for rows nobody owns. One a live `delete` is still walking down has an
  /// owner, and a second delete would only race the first into `waitForWorkerExit`.
  @Test func aRowALiveDeleteAlreadyOwnsIsNotRetried() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      try await harness.forceInstanceState(record.id, to: .deleting)
      let clock = TestClock()
      let reconciler = harness.instanceReconciler(now: { clock.now })
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)

      // A worker that answers `worker.shutdown` and keeps serving is what wedges a real delete: it
      // waits out the whole worker-exit budget and then throws, with the row still in `deleting`.
      await harness.launcher.worker(for: record.id)?.setExitHandler {}
      let manager = harness.instances
      let id = record.id
      let stuck = Task { try? await manager.delete(id: id) }
      try await waitUntil("the delete to take ownership of the row") {
        await manager.isTearingDown(id)
      }

      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)

      _ = try await withHangGuard("the wedged delete to give up") { await stuck.value }
      #expect(try await harness.record(id).state == .deleting)
      // Deferred, not dropped: with the owner gone the next tick picks the same row up.
      await harness.launcher.killWorker(id)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await harness.awaitInstance(id, state: .deleted)
    }
  }

  /// A row nothing can delete must not be retried on every tick: the retry logs, increments a
  /// counter and takes the single retry slot, so an unthrottled one is both noise and a blockage.
  @Test func aWedgedRowIsRetriedAtMostOncePerGrace() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      // A worker that answers `worker.shutdown` and keeps serving: every retry fails and the row
      // stays exactly where it is.
      await harness.launcher.worker(for: record.id)?.setExitHandler {}
      try await harness.forceInstanceState(record.id, to: .deleting)
      let clock = TestClock()
      let reconciler = harness.instanceReconciler(now: { clock.now })
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)

      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await withHangGuard("the first retry to give up") { await reconciler.awaitPendingRetry() }

      // Same clock, same still-stuck row: the grace was re-armed when the retry was issued.
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)
      #expect(try await harness.record(record.id).state == .deleting)

      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await withHangGuard("the reconciler to stop") { await reconciler.stop() }
    }
  }

  /// The loop stops at the first row it launches a retry for, so without the re-arm a permanently
  /// wedged row would be picked every tick and nothing behind it would ever be looked at.
  @Test func aWedgedRowDoesNotStarveTheOtherStuckRows() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var wedged: [InstanceID: FakeWorker] = [:]
      for _ in 0..<2 {
        let record = try await harness.instances.create(profileName: "linux")
        let worker = try #require(await harness.launcher.worker(for: record.id))
        await worker.setExitHandler {}
        try await harness.forceInstanceState(record.id, to: .deleting)
        wedged[record.id] = worker
      }
      let clock = TestClock()
      let reconciler = harness.instanceReconciler(now: { clock.now })
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)
      clock.advance(by: 600)

      // Each retry sends one `worker.shutdown`, which is the per-row evidence of whose turn it was.
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await withHangGuard("the first retry to give up") { await reconciler.awaitPendingRetry() }
      var attempts: [Int] = []
      for worker in wedged.values { attempts.append(await worker.shutdownRequests) }
      #expect(attempts.sorted() == [0, 1])

      // Same clock: the row just retried is no longer due, so the other one gets its turn.
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await withHangGuard("the second retry to give up") { await reconciler.awaitPendingRetry() }
      attempts = []
      for worker in wedged.values { attempts.append(await worker.shutdownRequests) }
      #expect(attempts == [1, 1])

      // And with both re-armed, a third tick at the same clock retries neither.
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)
      try await withHangGuard("the reconciler to stop") { await reconciler.stop() }
    }
  }

  /// The retry deliberately outlives the tick that launched it, so the daemon has to be able to
  /// take it back: `teardown` cancels and joins it before the worker connections go.
  @Test func stoppingTheReconcilerCancelsAParkedRetry() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.launcher.worker(for: record.id)?.setExitHandler {}
      try await harness.forceInstanceState(record.id, to: .deleting)
      let clock = TestClock()
      let reconciler = harness.instanceReconciler(now: { clock.now })
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 0)
      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)

      try await withHangGuard("the reconciler to cancel its retry") { await reconciler.stop() }

      // The delete never landed, and the slot it held is free again.
      #expect(try await harness.record(record.id).state == .deleting)
      clock.advance(by: 600)
      #expect(try await reconciler.run(firstTick: false).deletingRetried == 1)
      try await withHangGuard("the reconciler to stop") { await reconciler.stop() }
    }
  }

  // MARK: - D5b: a pull that never finished

  /// After a crash the `pull-image` operation row is *always* left `running` — the daemon that
  /// owned it never got to finish it — so on the first tick that row proves nothing. The in-flight
  /// map does: nothing this process did not itself register can be pulling yet.
  @Test func aCrashedPullIsInvalidatedOnTheFirstTickDespiteItsRunningOperation() async throws {
    try await withHarness { harness in
      let row = Self.linuxImageRow(state: .pulling)
      try await harness.imageRows.upsert(row)
      let operations = GRDBOperationRepository(db: harness.database)
      let operation = try await operations.start(
        kind: ImageManager.pullOperationKind, resourceType: "image",
        resourceId: row.digest.rawValue, idempotencyKey: nil)

      _ = try await harness.instanceReconciler().run(firstTick: true)

      #expect(try await harness.imageRows.get(digest: row.digest)?.state == .invalid)
      // The operation row is left exactly as it was, and so is the staging directory: a later pull
      // adopts the one through `restart` and resumes into the other.
      let after = try #require(
        try await operations.list(state: nil).first { $0.id == operation.id })
      #expect(after.state == .running)
      #expect(after.finishedAt == nil)
    }
  }

  /// Past the first tick the same row may belong to a pull that is resuming, so the operation row
  /// is consulted again and a `running` one is proof the sweep must keep its hands off.
  @Test func aPullingRowWithARunningOperationIsLeftAloneAfterTheFirstTick() async throws {
    try await withHarness { harness in
      let row = Self.linuxImageRow(state: .pulling)
      try await harness.imageRows.upsert(row)
      _ = try await GRDBOperationRepository(db: harness.database).start(
        kind: ImageManager.pullOperationKind, resourceType: "image",
        resourceId: row.digest.rawValue, idempotencyKey: nil)

      _ = try await harness.instanceReconciler().run(firstTick: false)

      #expect(try await harness.imageRows.get(digest: row.digest)?.state == .pulling)
    }
  }

  /// The steady-state defect: `performPull` marks a failed transfer `invalid` with a `try?`, so one
  /// bad write leaves a row claiming a transfer that ended and pins its digest against
  /// `image prune`. Its operation row is finished, so the sweep catches it on any tick.
  @Test func aPullingRowWhoseOperationIsOverIsInvalidatedOnALaterTick() async throws {
    try await withHarness { harness in
      let row = Self.linuxImageRow(state: .pulling)
      try await harness.imageRows.upsert(row)

      _ = try await harness.instanceReconciler().run(firstTick: false)

      #expect(try await harness.imageRows.get(digest: row.digest)?.state == .invalid)
    }
  }

  // MARK: - D9: a cancel that keeps failing

  @Test func aFailedCancelIsCountedWithItsErrorCodeAndClearedWhenItLands() async throws {
    try await withHarness { harness in
      let (instance, agent) = try await harness.idleInstance()
      // Same wedge as above: the cancel's delete cannot prove the worker is gone, so it throws.
      await harness.launcher.worker(for: instance.id)?.setExitHandler {}
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual)
      let labels = [
        "profile": "linux", "code": VMError.workerLockHeldByOtherProcess(path: "").code,
      ]

      await orchestrator.tick()
      await orchestrator.drainCancels()

      #expect(await orchestrator.cancelFailures[instance.id] == 1)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.instanceCancelFailuresTotal, labels: labels) == 1)

      // The scheduler only ever cancels an `idle` row, and a failed cancel parks this one in
      // `deleting` — which is D5's business, not the tick's. Putting it back is how a test gets
      // the same instance in front of the same pass a second time.
      try await harness.forceInstanceState(instance.id, to: .idle)
      await orchestrator.tick()
      await orchestrator.drainCancels()

      #expect(await orchestrator.cancelFailures[instance.id] == 2)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.instanceCancelFailuresTotal, labels: labels) == 2)

      await harness.launcher.killWorker(instance.id)
      try await harness.forceInstanceState(instance.id, to: .idle)
      await orchestrator.tick()
      await orchestrator.drainCancels()

      #expect(try await harness.record(instance.id).state == .deleted)
      #expect(await orchestrator.cancelFailures[instance.id] == nil)
      await agent.stop()
    }
  }

  /// The counter is keyed by instance id, so it has to be pruned like `workerCPU` is: a row that
  /// reached `deleted` can never be cancelled again, and its entry must not outlive it.
  @Test func failureCountsAreDroppedOnceTheRowIsGone() async throws {
    try await withHarness { harness in
      let (instance, agent) = try await harness.idleInstance()
      await harness.launcher.worker(for: instance.id)?.setExitHandler {}
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainCancels()
      #expect(await orchestrator.cancelFailures[instance.id] == 1)

      // Deleted by something other than a cancel, so nothing clears the entry on the way out.
      await harness.launcher.killWorker(instance.id)
      _ = try await harness.instances.delete(id: instance.id)
      await orchestrator.tick()
      await orchestrator.drainCancels()

      #expect(await orchestrator.cancelFailures.isEmpty)
      await agent.stop()
    }
  }

  /// Every failure is counted, but the log is deliberately quieter than the ten-second tick.
  @Test func theCancelBackoffWarnsOnceThenEscalatesEveryThirtieth() {
    #expect(CancelBackoff.level(failures: 0) == nil)
    #expect(CancelBackoff.level(failures: 1) == .warning)
    for failures in 2...29 {
      #expect(CancelBackoff.level(failures: failures) == nil, "failure \(failures)")
    }
    #expect(CancelBackoff.level(failures: 30) == .error)
    #expect(CancelBackoff.level(failures: 31) == nil)
    #expect(CancelBackoff.level(failures: 60) == .error)
  }

  /// A family with no `MetricDefinition` has no help or type until something is observed into it,
  /// so it is absent from the first scrapes an operator looks at.
  @Test func bothNewFamiliesAreDeclaredInTheCatalogue() {
    let declared = Set(RunnerVMMetrics.definitions.map(\.name))
    #expect(declared.contains(RunnerVMMetrics.instanceDeleteRetriesTotal))
    #expect(declared.contains(RunnerVMMetrics.instanceCancelFailuresTotal))
    #expect(
      RunnerVMMetrics.definitions
        .first { $0.name == RunnerVMMetrics.instanceCancelFailuresTotal }?.kind == .counter)
  }
}
