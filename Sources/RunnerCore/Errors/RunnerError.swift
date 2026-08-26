import Foundation

/// Every domain error is machine-classifiable (spec §84). Scheduler and retry code branch on
/// `code`/`retryable` — never on a human-readable string.
public protocol RunnerError: Error, Sendable, CustomStringConvertible {
  /// Stable UPPER_SNAKE identifier. Persisted in `instances.failure_code` and logged.
  var code: String { get }
  var message: String { get }
  var retryable: Bool { get }
  var underlying: (any Error)? { get }
}

extension RunnerError {
  public var underlying: (any Error)? { nil }

  public var description: String {
    if let underlying {
      return "\(code): \(message) (\(underlying))"
    }
    return "\(code): \(message)"
  }
}
