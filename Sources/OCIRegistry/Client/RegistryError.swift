import Foundation
import RunnerCore

/// Transport-level registry failures.
///
/// Kept separate from `ImageError` because these classify an HTTP exchange, not an image: the
/// daemon maps them into `ImageError.pullFailed` at the boundary, keeping `underlying` for the
/// operator-facing detail.
public enum RegistryError: RunnerError {
  case authenticationRequired(registry: String, reason: String)
  case notFound(resource: String)
  /// Retryable server-side condition (429, 5xx, request timeout).
  case transient(operation: String, status: Int, detail: String)
  /// The exchange never produced a usable HTTP response (connection lost, DNS, TLS).
  case transport(operation: String, reason: String, cause: (any Error & Sendable)?)
  case invalidResponse(operation: String, reason: String)
  case digestMismatch(expected: String, actual: String)
  case unsupportedManifest(reason: String)

  public var code: String {
    switch self {
    case .authenticationRequired: "REGISTRY_AUTH"
    case .notFound: "REGISTRY_NOT_FOUND"
    case .transient: "REGISTRY_TRANSIENT"
    case .transport: "REGISTRY_TRANSPORT"
    case .invalidResponse: "REGISTRY_INVALID_RESPONSE"
    case .digestMismatch: "REGISTRY_DIGEST_MISMATCH"
    case .unsupportedManifest: "REGISTRY_UNSUPPORTED_MANIFEST"
    }
  }

  public var message: String {
    switch self {
    case let .authenticationRequired(registry, reason):
      "registry \(registry) rejected the credentials: \(reason)"
    case let .notFound(resource): "registry has no \(resource)"
    case let .transient(operation, status, detail):
      "\(operation) failed with HTTP \(status)\(Self.suffix(detail))"
    case let .transport(operation, reason, _): "\(operation) failed: \(reason)"
    case let .invalidResponse(operation, reason): "\(operation) returned an invalid response: \(reason)"
    case let .digestMismatch(expected, actual):
      "digest mismatch: expected \(expected), got \(actual)"
    case let .unsupportedManifest(reason): "unsupported manifest: \(reason)"
    }
  }

  public var retryable: Bool {
    switch self {
    case .transient, .transport: true
    case .authenticationRequired, .notFound, .invalidResponse, .digestMismatch, .unsupportedManifest:
      false
    }
  }

  public var underlying: (any Error)? {
    if case let .transport(_, _, cause) = self { return cause }
    return nil
  }

  private static func suffix(_ detail: String) -> String {
    detail.isEmpty ? "" : ": \(detail)"
  }

  /// Maps an HTTP status onto the classification the scheduler branches on.
  static func fromStatus(
    _ status: Int, operation: String, registry: String, detail: String
  ) -> RegistryError {
    switch status {
    case 401, 403: .authenticationRequired(
        registry: registry,
        reason: detail.isEmpty ? "HTTP \(status)" : detail
      )
    case 404: .notFound(resource: operation)
    case 408, 429, 500, 502, 503, 504: .transient(operation: operation, status: status, detail: detail)
    default: .invalidResponse(operation: operation, reason: "HTTP \(status)\(suffix(detail))")
    }
  }
}
