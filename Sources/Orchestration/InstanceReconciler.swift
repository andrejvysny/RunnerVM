import Foundation
import ImageStore
import Logging
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
  private let logger: Logger
  private let seenOrphans: OrphanLog
  private let images: ImageManager?

  public init(
    instances: any InstanceRepository, manager: InstanceManager, supervisor: WorkerSupervisor,
    store: InstanceStore, retention: @escaping @Sendable () async -> Duration,
    images: ImageManager? = nil, logger: Logger = Logger(component: .reconciler)
  ) {
    self.images = images
    self.instances = instances
    self.manager = manager
    self.supervisor = supervisor
    self.store = store
    self.retention = retention
    self.logger = logger
    self.seenOrphans = OrphanLog()
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
    counts.swept = await sweepRetired(retention: await retention())
    counts.orphans = await reportOrphans(known: Set(live.map(\.id)))
    _ = try? await store.sweepStaging(olderThan: await retention())
    return counts
  }

  /// Drops `failed`/`interrupted`/`stopped` ephemeral instances whose diagnostics have outlived
  /// the retention window (spec §110).
  private func sweepRetired(retention: Duration, now: Date = Date()) async -> Int {
    let cutoff = now.addingTimeInterval(-Double(retention.milliseconds) / 1000)
    guard let records = try? await instances.list(
      profile: nil, states: [.failed, .interrupted, .stopped]) else { return 0 }
    var swept = 0
    for record in records where record.lifecycle == .ephemeral {
      let marker = record.stoppedAt?.date ?? record.createdAt.date
      guard marker < cutoff else { continue }
      if (try? await manager.delete(id: record.id)) != nil { swept += 1 }
    }
    return swept
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
