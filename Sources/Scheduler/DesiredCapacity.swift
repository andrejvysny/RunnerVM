import Foundation
import RunnerCore

/// Desired state for one profile in one scheduling pass.
public struct DesiredPlan: Sendable, Hashable {
  /// Instances that should be serving assigned jobs.
  public var busyTarget: Int
  /// Warm instances on top of `busyTarget`; busy demand always wins the last slot.
  public var idleTarget: Int
  public var toStart: Int
  /// Newest cancellable reservations first; never contains a bound instance.
  public var toCancel: [InstanceID]

  public init(busyTarget: Int, idleTarget: Int, toStart: Int, toCancel: [InstanceID]) {
    self.busyTarget = busyTarget
    self.idleTarget = idleTarget
    self.toStart = toStart
    self.toCancel = toCancel
  }

  public var desiredTotal: Int {
    busyTarget + idleTarget
  }
}

/// Desired-capacity math from plan C1 "Capacity", which replaces the spec §15 clamp.
public enum DesiredCapacity {
  /// `reservations` are this profile's capacity-consuming reservations only; `capacity` is the
  /// result of `CapacityCalculator.profileCapacity` for the same profile and reservation set.
  public static func compute(
    profile: RunnerProfileConfig,
    assignedJobs: Int,
    reservations: [Reservation],
    capacity: ProfileCapacity
  ) -> DesiredPlan {
    let current = reservations.count
    let capTotal = max(0, current + capacity.cap)
    let busyTarget = min(max(0, assignedJobs), capTotal)
    let idleTarget = min(max(0, profile.warmPool.minIdle), capTotal - busyTarget)
    let desired = busyTarget + idleTarget
    let toStart = max(0, desired - current)
    let toCancel = cancellations(
      surplus: max(0, current - desired), reservations: reservations, profile: profile
    )
    return DesiredPlan(
      busyTarget: busyTarget, idleTarget: idleTarget, toStart: toStart, toCancel: toCancel
    )
  }

  /// Demand dropped: give back the reservations that cost the least to abandon. Pre-boot unbound
  /// instances go first and newest-first, because the newest has done the least clone/boot work;
  /// then idle instances above `maxIdle`, oldest-first, since the oldest is closest to its TTL.
  static func cancellations(
    surplus: Int,
    reservations: [Reservation],
    profile: RunnerProfileConfig
  ) -> [InstanceID] {
    guard surplus > 0 else { return [] }

    let preBoot = reservations
      .filter(\.isCancellablePreBoot)
      .sorted(by: newestFirst)
      .prefix(surplus)
      .map(\.instanceId)

    let remaining = surplus - preBoot.count
    guard remaining > 0 else { return Array(preBoot) }

    let idle = reservations.filter(\.isCancellableIdle).sorted(by: oldestFirst)
    let beyondMaxIdle = max(0, idle.count - max(0, profile.warmPool.maxIdle))
    let idleVictims = idle.prefix(min(remaining, beyondMaxIdle)).map(\.instanceId)
    return Array(preBoot) + idleVictims
  }

  /// Ties break on `instanceId` so two equal `createdAt` values (same transaction) still order.
  private static func newestFirst(_ lhs: Reservation, _ rhs: Reservation) -> Bool {
    lhs.createdAt == rhs.createdAt
      ? lhs.instanceId.rawValue < rhs.instanceId.rawValue
      : lhs.createdAt > rhs.createdAt
  }

  private static func oldestFirst(_ lhs: Reservation, _ rhs: Reservation) -> Bool {
    lhs.createdAt == rhs.createdAt
      ? lhs.instanceId.rawValue < rhs.instanceId.rawValue
      : lhs.createdAt < rhs.createdAt
  }
}
