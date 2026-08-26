import Foundation

/// Failures on the host↔guest control channel (spec §33–§35).
public enum GuestAgentError: RunnerError {
  case notReady(reason: String)
  /// The readiness deadline (`timeouts.agentReady`) elapsed before `agent.health` said `ready`.
  case readinessTimeout(seconds: Double, lastReason: String)
  case handshakeFailed(reason: String)
  case protocolVersionUnsupported(guest: Int, host: Int)
  /// The guest rebooted underneath us; every session-scoped assumption is void.
  case bootIDChanged(previous: String, current: String)
  case transportClosed(reason: String)
  case requestTimeout(method: String)
  case methodFailed(method: String, reason: String)
  case unhealthy(reason: String)
  case cleanupFailed(reason: String)
  case runnerStartFailed(reason: String)
  case diskResizeFailed(reason: String)
  case payloadTooLarge(bytes: Int, limit: Int)

  public var code: String {
    switch self {
    case .notReady: "AGENT_NOT_READY"
    case .readinessTimeout: "AGENT_READY_TIMEOUT"
    case .handshakeFailed: "AGENT_HANDSHAKE_FAILED"
    case .protocolVersionUnsupported: "AGENT_PROTOCOL_VERSION_UNSUPPORTED"
    case .bootIDChanged: "AGENT_BOOT_ID_CHANGED"
    case .transportClosed: "AGENT_TRANSPORT_CLOSED"
    case .requestTimeout: "AGENT_REQUEST_TIMEOUT"
    case .methodFailed: "AGENT_METHOD_FAILED"
    case .unhealthy: "AGENT_UNHEALTHY"
    case .cleanupFailed: "AGENT_CLEANUP_FAILED"
    case .runnerStartFailed: "AGENT_RUNNER_START_FAILED"
    case .diskResizeFailed: "AGENT_DISK_RESIZE_FAILED"
    case .payloadTooLarge: "AGENT_PAYLOAD_TOO_LARGE"
    }
  }

  public var message: String {
    switch self {
    case .notReady(let reason): "guest agent not ready: \(reason)"
    case .readinessTimeout(let seconds, let lastReason):
      "guest agent was not ready within \(seconds)s: \(lastReason)"
    case .handshakeFailed(let reason): "guest agent handshake failed: \(reason)"
    case .protocolVersionUnsupported(let guest, let host):
      "guest speaks protocol \(guest), host speaks \(host)"
    case .bootIDChanged(let previous, let current): "guest rebooted (\(previous) -> \(current))"
    case .transportClosed(let reason): "guest transport closed: \(reason)"
    case .requestTimeout(let method): "guest did not answer \(method) in time"
    case .methodFailed(let method, let reason): "\(method) failed: \(reason)"
    case .unhealthy(let reason): "guest agent unhealthy: \(reason)"
    case .cleanupFailed(let reason): "guest cleanup failed: \(reason)"
    case .runnerStartFailed(let reason): "guest could not start the runner: \(reason)"
    case .diskResizeFailed(let reason): "guest disk resize failed: \(reason)"
    case .payloadTooLarge(let bytes, let limit): "payload \(bytes)B exceeds channel limit \(limit)B"
    }
  }

  public var retryable: Bool {
    switch self {
    case .notReady, .transportClosed, .requestTimeout:
      true
    // A reboot, a version gap or a failed cleanup taints the instance: retrying the call cannot fix it.
    // A readiness timeout is terminal for this boot: the instance fails and is kept for diagnostics.
    case .readinessTimeout, .handshakeFailed, .protocolVersionUnsupported, .bootIDChanged,
         .methodFailed, .unhealthy, .cleanupFailed, .runnerStartFailed, .diskResizeFailed,
         .payloadTooLarge:
      false
    }
  }
}
