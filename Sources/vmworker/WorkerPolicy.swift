import Foundation

/// What `WorkerPolicy.decide` concluded the worker should do.
enum WorkerPolicyDecision {
  case none
  case hardDeadline
  case orphanIdle
}

/// The lease/deadline/orphan decision behind `WorkerService.evaluatePolicy`, pulled out into a pure
/// function so the four-way branch is testable without a running VM.
///
/// A worker with no live lease must not outlive the daemon that spawned it, and one past its
/// `hardDeadline` must not outlive that deadline even while runnerd keeps renewing the lease or a
/// job is still connected -- checking the deadline first and unconditionally is what fixes that.
enum WorkerPolicy {
  static func decide(
    now: Date, hardDeadline: Date?, leaseExpiresAt: Date?, activeConnections: Int,
    orphanIdleSince: Date?, orphanIdle: TimeInterval
  ) -> (decision: WorkerPolicyDecision, orphanIdleSince: Date?) {
    if let hardDeadline, now >= hardDeadline {
      return (.hardDeadline, nil)
    }
    if let leaseExpiresAt, leaseExpiresAt > now {
      return (.none, nil)
    }
    guard activeConnections == 0 else {
      return (.none, nil)
    }
    let since = orphanIdleSince ?? now
    if now.timeIntervalSince(since) >= orphanIdle {
      return (.orphanIdle, since)
    }
    return (.none, since)
  }
}
