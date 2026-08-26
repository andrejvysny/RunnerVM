import Foundation

/// Exponential backoff with jitter (spec §52). `delay(forAttempt:)` is a pure function so the
/// schedule can be asserted in tests without sleeping.
public struct RetryPolicy: Hashable, Sendable {
  public var maxAttempts: Int
  public var baseDelay: Duration
  public var maxDelay: Duration
  /// Fraction of the computed delay used as jitter spread, 0...1.
  public var jitter: Double
  public var multiplier: Double

  public init(
    maxAttempts: Int = 5,
    baseDelay: Duration = .milliseconds(500),
    maxDelay: Duration = .seconds(30),
    jitter: Double = 0.2,
    multiplier: Double = 2.0
  ) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitter = jitter
    self.multiplier = multiplier
  }

  /// Network calls to GitHub: longer ceiling because `Retry-After` can legitimately exceed a minute.
  public static let github = RetryPolicy(
    maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(60), jitter: 0.2, multiplier: 2.0
  )

  /// Local operations (SQLite busy, worker socket connect): fast, tight ceiling.
  public static let local = RetryPolicy(
    maxAttempts: 4, baseDelay: .milliseconds(100), maxDelay: .seconds(2), jitter: 0.1, multiplier: 2.0
  )

  // MARK: - Schedule

  /// - Parameter attempt: 1 for the delay after the first failure.
  /// - Parameter retryAfter: server-supplied wait. It overrides the backoff curve and is *not*
  ///   clamped by `maxDelay`; retrying earlier than GitHub asked only deepens a rate limit.
  /// - Parameter random: injected for determinism in tests.
  public func delay(
    forAttempt attempt: Int,
    retryAfter: Duration? = nil,
    random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
  ) -> Duration {
    let spread = jitter.clamped(to: 0...1)
    if let retryAfter, retryAfter > .zero {
      // Jitter only upward here, for the reason above.
      return Self.scale(retryAfter, by: spread > 0 ? random(1.0...(1.0 + spread)) : 1.0)
    }
    let step = max(1, attempt) - 1
    let growth = pow(max(1.0, multiplier), Double(step))
    let raw = Self.seconds(baseDelay) * (growth.isFinite ? growth : .greatestFiniteMagnitude)
    let capped = min(raw, Self.seconds(maxDelay))
    guard capped > 0 else { return .zero }
    let factor = spread > 0 ? random((1.0 - spread)...(1.0 + spread)) : 1.0
    return .seconds(max(0, capped * factor))
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  private static func scale(_ duration: Duration, by factor: Double) -> Duration {
    .seconds(max(0, seconds(duration) * factor))
  }

  // MARK: - Execution

  /// Runs `operation`, retrying while `shouldRetry` accepts the error and attempts remain.
  /// `sleep` and `random` are injectable so the whole loop is testable without wall-clock time.
  public func run<T>(
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
    retryAfter: (any Error) -> Duration? = { _ in nil },
    shouldRetry: (any Error) -> Bool = { _ in true },
    _ operation: () async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do {
        return try await operation()
      } catch {
        guard attempt < maxAttempts, shouldRetry(error), !(error is CancellationError) else { throw error }
        try Task.checkCancellation()
        try await sleep(delay(forAttempt: attempt, retryAfter: retryAfter(error), random: random))
        attempt += 1
      }
    }
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
