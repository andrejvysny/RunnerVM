import Foundation

/// Failures owned by `vmworker` supervision and the Virtualization layer.
public enum VMError: RunnerError {
  case specInvalid(reason: String)
  case workerSpawnFailed(reason: String, cause: (any Error & Sendable)?)
  /// hello carried a different instance/generation/nonce/specDigest: a stale worker, never trusted.
  case workerFenced(reason: String)
  case workerUnresponsive(reason: String)
  case workerLockHeldByOtherProcess(path: String)
  case bootTimeout(stage: String)
  case guestStopTimeout
  case forceStopFailed(reason: String)
  case unsupportedGuestOS(GuestOS)
  case hostCapabilityMissing(capability: String)
  case macOSGuestLimitReached(limit: Int)

  public var code: String {
    switch self {
    case .specInvalid: "VM_SPEC_INVALID"
    case .workerSpawnFailed: "VM_WORKER_SPAWN_FAILED"
    case .workerFenced: "VM_WORKER_FENCED"
    case .workerUnresponsive: "VM_WORKER_UNRESPONSIVE"
    case .workerLockHeldByOtherProcess: "VM_WORKER_LOCK_HELD"
    case .bootTimeout: "VM_BOOT_TIMEOUT"
    case .guestStopTimeout: "VM_GUEST_STOP_TIMEOUT"
    case .forceStopFailed: "VM_FORCE_STOP_FAILED"
    case .unsupportedGuestOS: "VM_UNSUPPORTED_GUEST_OS"
    case .hostCapabilityMissing: "VM_HOST_CAPABILITY_MISSING"
    case .macOSGuestLimitReached: "VM_MACOS_GUEST_LIMIT_REACHED"
    }
  }

  public var message: String {
    switch self {
    case .specInvalid(let reason): "VM specification rejected: \(reason)"
    case .workerSpawnFailed(let reason, _): "could not spawn vmworker: \(reason)"
    case .workerFenced(let reason): "worker handshake fenced: \(reason)"
    case .workerUnresponsive(let reason): "vmworker did not respond: \(reason)"
    case .workerLockHeldByOtherProcess(let path): "worker lock still held: \(path)"
    case .bootTimeout(let stage): "timed out waiting for \(stage)"
    case .guestStopTimeout: "guest did not stop before the graceful shutdown timeout"
    case .forceStopFailed(let reason): "force stop failed: \(reason)"
    case .unsupportedGuestOS(let os): "guest OS \(os.rawValue) is not supported on this host"
    case .hostCapabilityMissing(let capability): "host lacks required capability: \(capability)"
    case .macOSGuestLimitReached(let limit): "macOS guest limit of \(limit) reached"
    }
  }

  public var retryable: Bool {
    switch self {
    // A boot/stop timeout or a busy host is worth another instance; a bad spec or missing
    // capability will fail identically forever.
    case .workerSpawnFailed, .workerUnresponsive, .bootTimeout, .guestStopTimeout,
         .workerLockHeldByOtherProcess, .macOSGuestLimitReached:
      true
    case .specInvalid, .workerFenced, .forceStopFailed, .unsupportedGuestOS, .hostCapabilityMissing:
      false
    }
  }

  public var underlying: (any Error)? {
    if case .workerSpawnFailed(_, let cause) = self { return cause }
    return nil
  }
}
