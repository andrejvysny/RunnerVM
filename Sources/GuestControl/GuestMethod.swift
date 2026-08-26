import RPC

/// Method catalogue of the `guest` protocol (Proto/guest_agent.md). Shared by runnerd and the
/// Go guest agent; the raw values are the wire names and must never drift.
public enum GuestMethod: String, CaseIterable, Sendable, Hashable {
  case hello = "agent.hello"
  case health = "agent.health"
  case getInfo = "agent.getInfo"
  case getMetrics = "agent.getMetrics"
  case resizeDisk = "agent.resizeDisk"
  case startRunner = "agent.startRunner"
  case runnerStatus = "agent.runnerStatus"
  case stopRunner = "agent.stopRunner"
  case cleanup = "agent.cleanup"
  case exec = "agent.exec"
  case shutdown = "agent.shutdown"

  /// The protocol table marks `agent.exec` only as `stream`; retry safety still has to be stated,
  /// and re-running an arbitrary argv after a transport failure is never safe.
  public var methodClass: MethodClass {
    switch self {
    case .hello, .health, .getInfo, .getMetrics, .runnerStatus: .readOnly
    case .resizeDisk, .stopRunner, .cleanup: .idempotentMutation
    case .startRunner, .exec, .shutdown: .singleShot
    }
  }

  public var isStreaming: Bool { self == .exec }
}

public enum GuestProtocolVersion {
  public static let current = 1
}

/// Guest-specific wire error codes, layered on the shared `RPCErrorCode` set.
public enum GuestErrorCode {
  /// `agent.startRunner` replayed with a `sessionId` the agent already spawned.
  public static let alreadyStarted = "ALREADY_STARTED"
  /// The method exists but this guest OS cannot honour it (macOS `agent.resizeDisk` in v1).
  public static let notSupported = "NOT_SUPPORTED"
}
