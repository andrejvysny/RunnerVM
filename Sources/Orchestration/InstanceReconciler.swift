import Foundation
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// The M2 reconcile steps: adopt surviving workers on the first tick, interrupt instances whose
/// worker is provably gone, expire failed instances, and notice directories nobody owns.
public struct InstanceReconciler: ReconcileStep {
  private let instances: any InstanceRepository
  private let manager: InstanceManager
  private let supervisor: WorkerSupervisor
  private let store: InstanceStore
  private let retention: @Sendable () async -> Duration
  private let now: @Sendable () -> Date
  /// How long a row may sit in `deleting` before the sweep re-issues the delete. Long enough that
  /// an ordinary teardown — which waits out the guest's graceful shutdown — is never retried under
  /// itself.
  private let deletingRetryGrace: Duration
  private let logger: Logger
  private let seenOrphans: OrphanLog
  private let stuckDeletes: DeletingLog
  private let images: ImageManager?

  public init(
    instances: any InstanceRepository, manager: InstanceManager, supervisor: WorkerSupervisor,
    store: InstanceStore, retention: @escaping @Sendable () async -> Duration,
    images: ImageManager? = nil, now: @escaping @Sendable () -> Date = { Date() },
    deletingRetryGrace: Duration = .seconds(300),
    logger: Logger = Logger(component: .reconciler)
  ) {
    self.images = images
    self.instances = instances
    self.manager = manager
    self.supervisor = supervisor
    self.store = store
    self.retention = retention
    self.now = now
    self.deletingRetryGrace = deletingRetryGrace
    self.logger = logger
    self.seenOrphans = OrphanLog()
    self.stuckDeletes = DeletingLog()
  }

  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    var counts = ReconcileCounts()
    let live = try await instances.list(profile: nil, states: nil).filter { $0.state != .deleted }
    counts.instances = live.count

    if firstTick {
      let liveness = await supervisor.reconnectAll(instances: live)
      // Adopting a worker says nothing about its guest: the agent has to be re-handshaked, and an
      // `idle` instance has to prove it did not reboot while runnerd was away.
      await manager.recheckAgents()
      // A crash between image reservation and the `planned` insert leaves a planning pin behind.
      try? await images?.sweepStalePlanningPins(knownInstanceIDs: Set(live.map(\.id)))
      logger.info(
        "worker recovery",
        metadata: [
          "connected": .stringConvertible(liveness.values.count { $0 == .connected }),
          "dead": .stringConvertible(liveness.values.count { $0 == .dead }),
        ])
    }
    counts.interrupted = await interruptDeadWorkers(live)
    counts.workersConnected = await supervisor.connectedCount
    await supervisor.reapExitedChildren()
    let sweptAt = now()
    counts.swept = await sweepRetired(retention: await retention(), now: sweptAt)
    counts.deletingRetried = await retryStuckDeletes(now: sweptAt)
    // A pull whose row never left `pulling` pins its digest against `image prune` forever. The
    // first tick is the one that can be sure: nothing this process did not itself register can be
    // in flight then, so the operation row is not consulted.
    await images?.sweepStalePulls(firstTick: firstTick)
    counts.orphans = await reportOrphans(known: Set(live.map(\.id)))
    _ = try? await store.sweepStaging(olderThan: await retention())
    // `images.prefetch` retry. A no-op when the flag is off or every profile image is already in
    // the store; this is what makes a prefetch that failed at apply time (registry unreachable, no
    // credential yet) eventually succeed without another `config apply`.
    await images?.prefetchProfileImages()
    return counts
  }

  /// Cancels and joins the delete retry this reconciler may have in flight.
  ///
  /// `DaemonRuntime.teardown` calls it alongside the other tracked tasks and before the worker
  /// connections go: the retry holds the instance manager and is the one piece of this step that
  /// deliberately outlives a tick.
  public func stop() async {
    await stuckDeletes.shutdown()
  }

  /// Test seam: waits for the retry a tick launched, without cancelling it.
  func awaitPendingRetry() async {
    await stuckDeletes.joinRetry()
  }

  /// Drops `failed`/`interrupted`/`stopped` instances whose diagnostics have outlived the
  /// retention window (spec §110).
  ///
  /// Lifecycle is deliberately not a filter. Restart eligibility is decided synchronously from the
  /// *predecessor* state inside `handleWorkerDisconnect`/`markWorkerDead` and is never persisted,
  /// and no caller walks `stopped -> startingWorker`, so any row a sweep can see has already lost
  /// its restart whatever its lifecycle. A reusable VM that never reached `idle` used to sit here
  /// forever, holding its cpu, memory, disk reservation, image pin and directory.
  ///
  /// Two rows are left alone: one an in-flight `delete`/`respawn` already owns, and a maintenance
  /// row still inside its pin — `MaintenanceInstanceReaper` is the only thing allowed to reclaim
  /// one of those, and only once `pinnedUntil` has passed.
  private func sweepRetired(retention: Duration, now: Date) async -> Int {
    let cutoff = now.addingTimeInterval(-Double(retention.milliseconds) / 1000)
    guard let records = try? await instances.list(
      profile: nil, states: [.failed, .interrupted, .stopped]) else { return 0 }
    var swept = 0
    for record in records {
      let marker = record.stoppedAt?.date ?? record.createdAt.date
      guard marker < cutoff else { continue }
      if record.purpose == .maintenance, let pinned = record.pinnedUntil?.date, pinned > now {
        continue
      }
      guard await !manager.isTearingDown(record.id), await !manager.isRestarting(record.id)
      else { continue }
      // Committed against the state judged above rather than against whatever the row says by the
      // time the delete gets there: everything from the `list` to here is a suspension point.
      guard case .deleted = try? await manager.delete(
        id: record.id, expectedState: record.state) else { continue }
      swept += 1
    }
    return swept
  }

  /// Re-issues a delete that never finished. A `delete` can throw with the row already in
  /// `deleting` (a worker still holding its lock, an unreadable directory), and nothing else ever
  /// looks at that row again — it holds its whole reservation until a restart or an operator.
  ///
  /// There is no `deleting_at` column and `delete` from `idle` stamps no `stoppedAt`, so the age
  /// is tracked in memory. Losing it on restart is correct: no in-process delete survives one, so
  /// every `deleting` row a fresh daemon sees is stuck by definition and starts its grace over.
  ///
  /// One row per tick, off the reconcile loop and never two at once: the retry waits out
  /// `waitForWorkerExit`, which a wedged worker holds open for the full poll budget.
  private func retryStuckDeletes(now: Date) async -> Int {
    guard let records = try? await instances.list(profile: nil, states: [.deleting]) else {
      return 0
    }
    let cutoff = now.addingTimeInterval(-Double(deletingRetryGrace.milliseconds) / 1000)
    let due = await stuckDeletes.observe(records.map(\.id), now: now, cutoff: cutoff)
    for record in records where due.contains(record.id) {
      // Its owner is mid-teardown and will finish it; a second delete would only race the first.
      guard await !manager.isTearingDown(record.id) else { continue }
      // Re-arms this row's grace as it claims the slot, so a permanently wedged row is retried
      // once per grace instead of on every tick — and cannot starve the rows behind it, since the
      // loop stops at the first row it launches.
      guard await stuckDeletes.beginRetry(record.id, at: now) else { return 0 }
      let manager = manager
      let logger = logger
      let log = stuckDeletes
      let deadline = deletingRetryGrace * 2
      let profile = await manager.profileName(record.profileId)
      let metrics = await manager.metricRegistry()
      let id = record.id
      await log.track(Task {
        await metrics.increment(
          RunnerVMMetrics.instanceDeleteRetriesTotal,
          labels: [RunnerVMMetrics.profileLabel: profile])
        logger.warning("retrying a stuck delete", metadata: .context(instance: id))
        await Self.attemptDelete(id, manager: manager, deadline: deadline, logger: logger)
        await log.endRetry()
      })
      return 1
    }
    return 0
  }

  /// One retry, bounded. A `delete` that never returns would otherwise hold the single retry slot
  /// for the life of the daemon and stop every other stuck row from ever being looked at.
  /// `waitForWorkerExit` suspends between polls, so cancelling this unwinds it.
  private static func attemptDelete(
    _ id: InstanceID, manager: InstanceManager, deadline: Duration, logger: Logger
  ) async {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        do {
          _ = try await manager.delete(id: id)
        } catch {
          logger.warning(
            "stuck delete retry failed",
            metadata: .context(instance: id)
              .merging(["error": .string(String(describing: error))]) { $1 })
        }
        return true
      }
      group.addTask {
        try? await Task.sleep(for: deadline)
        return false
      }
      // `false` is the timer winning. Cancellation resumes the sleeper the same way, so an
      // ordinary shutdown is not reported as a timeout.
      if await group.next() == false, !Task.isCancelled {
        logger.error("stuck delete retry timed out", metadata: .context(instance: id))
      }
      group.cancelAll()
    }
  }

  /// A running instance whose worker holds neither a lock nor a socket has lost its VM. The lock
  /// is the authority here — a pid is not, because pids are recycled.
  private func interruptDeadWorkers(_ records: [InstanceRecord]) async -> Int {
    var interrupted = 0
    for record in records where InstanceManager.interruptibleStates.contains(record.state) {
      guard record.workerGeneration > 0 else { continue }
      guard await supervisor.liveness(id: record.id) == .dead else { continue }
      await manager.markWorkerDead(id: record.id)
      interrupted += 1
    }
    return interrupted
  }

  /// Directories with no owning row. v1 only reports them; deletion needs the grace policy from
  /// spec §111, which lands with the orphan sweep in a later milestone.
  private func reportOrphans(known: Set<InstanceID>) async -> Int {
    guard let directories = try? await store.listDirectories() else { return 0 }
    let orphans = directories.filter { !known.contains($0) }
    for orphan in await seenOrphans.newlySeen(orphans) {
      logger.warning("orphan instance directory", metadata: .context(instance: orphan))
    }
    await seenOrphans.retain(Set(orphans))
    return orphans.count
  }
}

/// Keeps "orphan detected" to one line per directory instead of one per tick.
private actor OrphanLog {
  private var reported: Set<InstanceID> = []

  func newlySeen(_ candidates: [InstanceID]) -> [InstanceID] {
    candidates.filter { !reported.contains($0) }
  }

  func retain(_ current: Set<InstanceID>) {
    reported = current
  }
}

/// How long each row has been sitting in `deleting`, plus the one retry the reconciler allows to
/// be in flight at a time.
private actor DeletingLog {
  private var firstSeen: [InstanceID: Date] = [:]
  private var retrying = false
  private var retry: Task<Void, Never>?

  /// Records `current`, forgets everything that has left `deleting`, and answers which of them
  /// were already there before `cutoff`. A row is never due on the tick that first sees it, which
  /// is what keeps an ordinary teardown from being retried under itself.
  func observe(_ current: [InstanceID], now: Date, cutoff: Date) -> Set<InstanceID> {
    let live = Set(current)
    firstSeen = firstSeen.filter { live.contains($0.key) }
    var due: Set<InstanceID> = []
    for id in current {
      let since = firstSeen[id] ?? now
      firstSeen[id] = since
      if since < cutoff { due.insert(id) }
    }
    return due
  }

  /// Claims the single retry slot for `id` and restarts that row's grace from `at`, so the row
  /// just retried goes to the back of the queue instead of being due again on the next tick.
  /// Synchronous, so two ticks cannot both claim the slot.
  func beginRetry(_ id: InstanceID, at moment: Date) -> Bool {
    guard !retrying else { return false }
    retrying = true
    firstSeen[id] = moment
    return true
  }

  func track(_ task: Task<Void, Never>) {
    retry = task
  }

  func endRetry() {
    retrying = false
    retry = nil
  }

  /// Waits for the retry in flight, if any. The reconcile loop never does this — keeping the retry
  /// off it is the point — but shutdown and the tests need to know when it is over.
  func joinRetry() async {
    await retry?.value
  }

  /// Cancels the retry in flight and waits for it to unwind, so the daemon never tears down the
  /// instance manager out from under a delete that is still running.
  func shutdown() async {
    let inFlight = retry
    inFlight?.cancel()
    await inFlight?.value
    retrying = false
    retry = nil
  }
}
