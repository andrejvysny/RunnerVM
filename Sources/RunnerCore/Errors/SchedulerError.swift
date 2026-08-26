import Foundation

/// Admission and placement failures.
public enum SchedulerError: RunnerError {
  case insufficientCPU(requested: Int, availableBudget: Int)
  case insufficientMemory(requestedBytes: UInt64, availableBytes: UInt64)
  case insufficientDisk(requestedBytes: UInt64, availableBytes: UInt64)
  case profileAtMaxInstances(profile: String, limit: Int)
  case macOSGuestLimitReached(limit: Int)
  case hostDraining
  case hostOffline
  case startConcurrencyExhausted(limit: Int)
  case unknownProfile(name: String)
  case reservationCancelled(instanceID: InstanceID)

  public var code: String {
    switch self {
    case .insufficientCPU: "SCHEDULER_INSUFFICIENT_CPU"
    case .insufficientMemory: "SCHEDULER_INSUFFICIENT_MEMORY"
    case .insufficientDisk: "SCHEDULER_INSUFFICIENT_DISK"
    case .profileAtMaxInstances: "SCHEDULER_PROFILE_AT_MAX_INSTANCES"
    case .macOSGuestLimitReached: "SCHEDULER_MACOS_GUEST_LIMIT_REACHED"
    case .hostDraining: "SCHEDULER_HOST_DRAINING"
    case .hostOffline: "SCHEDULER_HOST_OFFLINE"
    case .startConcurrencyExhausted: "SCHEDULER_START_CONCURRENCY_EXHAUSTED"
    case .unknownProfile: "SCHEDULER_UNKNOWN_PROFILE"
    case .reservationCancelled: "SCHEDULER_RESERVATION_CANCELLED"
    }
  }

  public var message: String {
    switch self {
    case .insufficientCPU(let requested, let budget):
      "needs \(requested) vCPU, budget has \(budget)"
    case .insufficientMemory(let requested, let available):
      "needs \(ByteSize(bytes: requested)), only \(ByteSize(bytes: available)) available"
    case .insufficientDisk(let requested, let available):
      "needs \(ByteSize(bytes: requested)) of disk, only \(ByteSize(bytes: available)) available"
    case .profileAtMaxInstances(let profile, let limit):
      "profile \(profile) already has its maximum of \(limit) instances"
    case .macOSGuestLimitReached(let limit): "macOS guest limit of \(limit) reached"
    case .hostDraining: "host is draining and admits no new work"
    case .hostOffline: "host is offline"
    case .startConcurrencyExhausted(let limit): "already starting \(limit) VMs"
    case .unknownProfile(let name): "unknown profile '\(name)'"
    case .reservationCancelled(let id): "reservation for instance \(id) was cancelled"
    }
  }

  /// Capacity pressure clears on its own; a missing profile or a cancelled reservation does not.
  public var retryable: Bool {
    switch self {
    case .insufficientCPU, .insufficientMemory, .insufficientDisk, .profileAtMaxInstances,
         .macOSGuestLimitReached, .startConcurrencyExhausted, .hostDraining:
      true
    case .hostOffline, .unknownProfile, .reservationCancelled:
      false
    }
  }
}
