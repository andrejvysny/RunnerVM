import Foundation

/// Wire error codes. Deterministic UPPER_SNAKE strings shared with the Go guest agent.
public enum RPCErrorCode: String, Sendable, Hashable, CaseIterable, Codable {
  case protocolVersion = "PROTOCOL_VERSION"
  case protocolMismatch = "PROTOCOL_MISMATCH"
  case malformed = "MALFORMED"
  case unknownMethod = "UNKNOWN_METHOD"
  case invalidParams = "INVALID_PARAMS"
  case deadline = "DEADLINE"
  case cancelled = "CANCELLED"
  case busy = "BUSY"
  case internalError = "INTERNAL"
}

/// The `error` member of a response or terminal chunk.
public struct RPCErrorPayload: Sendable, Hashable, Codable {
  public let code: String
  public let message: String
  public let retryable: Bool

  public init(code: String, message: String, retryable: Bool = false) {
    self.code = code
    self.message = message
    self.retryable = retryable
  }

  public init(code: RPCErrorCode, message: String, retryable: Bool = false) {
    self.init(code: code.rawValue, message: message, retryable: retryable)
  }

  public var knownCode: RPCErrorCode? { RPCErrorCode(rawValue: code) }
}

/// Raised while turning bytes into an ``Envelope``.
///
/// `requestId` is carried when it could be salvaged from an otherwise invalid envelope, so the
/// server can answer with an error response instead of dropping the connection.
public struct EnvelopeError: Error, Sendable, Hashable {
  public let code: RPCErrorCode
  public let message: String
  public let requestId: String?

  public init(_ code: RPCErrorCode, _ message: String, requestId: String? = nil) {
    self.code = code
    self.message = message
    self.requestId = requestId
  }

  public var payload: RPCErrorPayload { RPCErrorPayload(code: code, message: message) }
}

/// Raised by ``RPCClient`` calls and streams.
public enum RPCCallError: Error, Sendable, Hashable {
  /// The peer answered with an `error` member.
  case remote(RPCErrorPayload)
  /// The connection went away before a terminal frame arrived.
  case disconnected
  /// The local deadline elapsed; a `cancel` envelope was sent.
  case deadlineExceeded
  /// The caller's task was cancelled; a `cancel` envelope was sent.
  case cancelled
  /// The local in-flight budget is exhausted.
  case tooManyInFlight
  /// The peer violated the envelope contract.
  case protocolViolation(String)

  public var payload: RPCErrorPayload? {
    if case .remote(let payload) = self { return payload }
    return nil
  }

  public var code: RPCErrorCode? {
    switch self {
    case .remote(let payload): return payload.knownCode
    case .disconnected: return nil
    case .deadlineExceeded: return .deadline
    case .cancelled: return .cancelled
    case .tooManyInFlight: return .busy
    case .protocolViolation: return .malformed
    }
  }
}

public enum RPCFrameError: Error, Sendable, Hashable {
  case invalidLength(Int, cap: Int)
}

public enum RPCServerError: Error, Sendable, Hashable {
  case notStarted
  case alreadyStarted
  case socketPathTooLong(String)
  case posix(operation: String, errno: Int32)
}
