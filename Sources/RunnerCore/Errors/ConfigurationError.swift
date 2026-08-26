import Foundation

/// Configuration load/validate/apply failures. Field-level problems are reported as
/// `[ConfigurationIssue]` instead; this enum covers the ones that abort the whole operation.
public enum ConfigurationError: RunnerError {
  case fileUnreadable(path: String, cause: (any Error & Sendable)?)
  case syntaxInvalid(path: String, reason: String)
  case unsupportedVersion(found: Int, supported: Int)
  /// Aggregate of every `severity == .error` issue from `RunnerConfiguration.validate(host:)`.
  case validationFailed(issues: [ConfigurationIssue])
  case socketPathTooLong(path: String, bytes: Int, limit: Int)
  case hostFactsUnavailable(reason: String)
  case applyConflict(reason: String)

  public var code: String {
    switch self {
    case .fileUnreadable: "CONFIG_FILE_UNREADABLE"
    case .syntaxInvalid: "CONFIG_SYNTAX_INVALID"
    case .unsupportedVersion: "CONFIG_UNSUPPORTED_VERSION"
    case .validationFailed: "CONFIG_VALIDATION_FAILED"
    case .socketPathTooLong: "SOCKET_PATH_TOO_LONG"
    case .hostFactsUnavailable: "CONFIG_HOST_FACTS_UNAVAILABLE"
    case .applyConflict: "CONFIG_APPLY_CONFLICT"
    }
  }

  public var message: String {
    switch self {
    case .fileUnreadable(let path, _): "cannot read configuration at \(path)"
    case .syntaxInvalid(let path, let reason): "\(path): \(reason)"
    case .unsupportedVersion(let found, let supported):
      "configuration version \(found) is not supported (expected \(supported))"
    case .validationFailed(let issues):
      "configuration rejected: " + issues.map { "\($0.path): \($0.code)" }.joined(separator: ", ")
    case .socketPathTooLong(let path, let bytes, let limit):
      "socket path \(path) is \(bytes) bytes, limit is \(limit)"
    case .hostFactsUnavailable(let reason): "cannot determine host capacity: \(reason)"
    case .applyConflict(let reason): "configuration apply conflicted: \(reason)"
    }
  }

  /// Configuration is operator input: nothing here improves by trying again.
  public var retryable: Bool { false }

  public var underlying: (any Error)? {
    if case .fileUnreadable(_, let cause) = self { return cause }
    return nil
  }
}
