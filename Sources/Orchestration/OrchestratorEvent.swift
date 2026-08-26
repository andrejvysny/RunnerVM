import Foundation
import RunnerCore

/// What one scheduling pass decided (spec §118).
///
/// Events wake reconciliation and give an operator a readable trace of *why* a VM appeared or
/// disappeared; they are never the source of truth. The persisted instance and session rows are.
public enum OrchestratorEvent: Sendable, Equatable {
  case demandChanged(profile: String, assignedJobs: Int)
  case capacityAdvertised(profile: String, capacity: Int)
  case instanceStarted(profile: String, instance: String)
  case instanceStartFailed(profile: String, reason: String)
  case instanceCancelled(profile: String, instance: String, reason: String)
  case sessionAssigned(profile: String, instance: String, session: String)
  case sessionAssignmentFailed(profile: String, instance: String, reason: String)
  case providerDegraded(profile: String, reason: String)

  public var profile: String {
    switch self {
    case let .demandChanged(profile, _): profile
    case let .capacityAdvertised(profile, _): profile
    case let .instanceStarted(profile, _): profile
    case let .instanceStartFailed(profile, _): profile
    case let .instanceCancelled(profile, _, _): profile
    case let .sessionAssigned(profile, _, _): profile
    case let .sessionAssignmentFailed(profile, _, _): profile
    case let .providerDegraded(profile, _): profile
    }
  }

  /// Stable machine-readable name; the log line carries it as `event`.
  public var name: String {
    switch self {
    case .demandChanged: "demand.changed"
    case .capacityAdvertised: "capacity.advertised"
    case .instanceStarted: "instance.started"
    case .instanceStartFailed: "instance.startFailed"
    case .instanceCancelled: "instance.cancelled"
    case .sessionAssigned: "session.assigned"
    case .sessionAssignmentFailed: "session.assignmentFailed"
    case .providerDegraded: "provider.degraded"
    }
  }

  public var detail: String {
    switch self {
    case let .demandChanged(_, jobs): "assignedJobs=\(jobs)"
    case let .capacityAdvertised(_, capacity): "capacity=\(capacity)"
    case let .instanceStarted(_, instance): instance
    case let .instanceStartFailed(_, reason): reason
    case let .instanceCancelled(_, instance, reason): "\(instance) (\(reason))"
    case let .sessionAssigned(_, instance, session): "\(instance) -> \(session)"
    case let .sessionAssignmentFailed(_, instance, reason): "\(instance): \(reason)"
    case let .providerDegraded(_, reason): reason
    }
  }
}

public struct OrchestratorEventRecord: Sendable, Equatable {
  public var at: Date
  public var event: OrchestratorEvent

  public init(at: Date, event: OrchestratorEvent) {
    self.at = at
    self.event = event
  }
}

/// Per-profile scheduling numbers the last tick worked from, for `system.status`.
public struct ProfileDemandState: Sendable, Equatable {
  public var assignedJobs: Int
  public var advertisedCapacity: Int
  public var starting: Int
  public var healthy: Bool

  public init(
    assignedJobs: Int = 0, advertisedCapacity: Int = 0, starting: Int = 0, healthy: Bool = true
  ) {
    self.assignedJobs = assignedJobs
    self.advertisedCapacity = advertisedCapacity
    self.starting = starting
    self.healthy = healthy
  }
}
