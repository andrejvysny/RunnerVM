import DaemonAPI
import Foundation
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Deletes maintenance instances whose `pinned_until` has passed (schema v4).
///
/// The scheduler deliberately cannot see a maintenance instance — that is what "pinned" means, and
/// it is why `demand dropped`, `idle ttl`, `tainted`/`retired` and session assignment all skip it.
/// This step is therefore the *only* thing that ever reclaims one, so it runs on every tick and
/// deletes through exactly the path `Orchestrator.cancel` and `instance.delete` use: the ladder in
/// `InstanceManager.delete`, which stops the worker, preserves the logs and unpins the image.
///
/// Idempotent like every other reconcile step: a delete that fails (a worker still holding its
/// lock, say) simply leaves the row for the next tick, which will find the same expired instance
/// and try again.
public struct MaintenanceInstanceReaper: ReconcileStep {
  private let instances: any InstanceRepository
  private let manager: InstanceManager
  private let events: LifecycleEventLog?
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    instances: any InstanceRepository, manager: InstanceManager,
    events: LifecycleEventLog? = nil, now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .reconciler)
  ) {
    self.instances = instances
    self.manager = manager
    self.events = events
    self.now = now
    self.logger = logger
  }

  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    var counts = ReconcileCounts()
    guard let rows = try? await instances.list(profile: nil, states: nil) else { return counts }
    let deadline = now()
    for record in rows where record.purpose == .maintenance && record.state != .deleted {
      guard let pinnedUntil = record.pinnedUntil?.date, pinnedUntil < deadline else { continue }
      guard await delete(record) else { continue }
      counts.swept += 1
    }
    return counts
  }

  private func delete(_ record: InstanceRecord) async -> Bool {
    do {
      _ = try await manager.delete(id: record.id)
    } catch {
      logger.warning(
        "could not reap an expired maintenance instance",
        metadata: .context(profile: record.profileId, instance: record.id).merging([
          "error": .string(String(describing: error)),
        ]) { $1 })
      return false
    }
    logger.notice(
      "maintenance instance expired",
      metadata: .context(profile: record.profileId, instance: record.id).merging([
        "pinned_until": .string(RFC3339.string(from: record.pinnedUntil?.date ?? Date())),
      ]) { $1 })
    await events?.record(
      LifecycleEventLog.instanceMaintenanceExpired,
      LifecycleEventLog.Fields(
        instance: record.id, profile: record.profileId, reason: "pinned ttl elapsed"))
    return true
  }
}
