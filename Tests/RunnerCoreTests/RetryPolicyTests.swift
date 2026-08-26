import Foundation
import RunnerCore
import Testing

@Suite struct RetryPolicyDelayTests {
  static let noJitter = RetryPolicy(
    maxAttempts: 6, baseDelay: .seconds(1), maxDelay: .seconds(30), jitter: 0, multiplier: 2
  )

  /// Always picks the bottom of the jitter range, making the schedule deterministic.
  static let lowest: @Sendable (ClosedRange<Double>) -> Double = { $0.lowerBound }
  static let highest: @Sendable (ClosedRange<Double>) -> Double = { $0.upperBound }

  @Test(arguments: [(1, 1.0), (2, 2.0), (3, 4.0), (4, 8.0), (5, 16.0)])
  func backoffGrowsGeometrically(attempt: Int, expected: Double) {
    #expect(Self.noJitter.delay(forAttempt: attempt, random: Self.lowest) == .seconds(expected))
  }

  @Test func backoffIsClampedByMaxDelay() {
    #expect(Self.noJitter.delay(forAttempt: 6, random: Self.lowest) == .seconds(30))
    #expect(Self.noJitter.delay(forAttempt: 99, random: Self.lowest) == .seconds(30))
  }

  @Test func attemptZeroAndNegativeBehaveLikeTheFirstAttempt() {
    #expect(Self.noJitter.delay(forAttempt: 0, random: Self.lowest) == .seconds(1))
    #expect(Self.noJitter.delay(forAttempt: -3, random: Self.lowest) == .seconds(1))
  }

  @Test func jitterStaysWithinTheConfiguredBand() {
    let policy = RetryPolicy(
      maxAttempts: 5, baseDelay: .seconds(4), maxDelay: .seconds(30), jitter: 0.25, multiplier: 2
    )
    let low = policy.delay(forAttempt: 1, random: Self.lowest)
    let high = policy.delay(forAttempt: 1, random: Self.highest)
    #expect(low == .seconds(3))
    #expect(high == .seconds(5))
    for _ in 0..<200 {
      let sample = policy.delay(forAttempt: 1)
      #expect(sample >= low && sample <= high)
    }
  }

  @Test func zeroJitterIsDeterministic() {
    let policy = RetryPolicy(baseDelay: .seconds(2), maxDelay: .seconds(60), jitter: 0, multiplier: 3)
    #expect(policy.delay(forAttempt: 2, random: Self.highest) == .seconds(6))
    #expect(policy.delay(forAttempt: 2, random: Self.lowest) == .seconds(6))
  }

  @Test func retryAfterOverridesTheBackoffCurve() {
    let policy = RetryPolicy(
      maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(30), jitter: 0, multiplier: 2
    )
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(45), random: Self.lowest) == .seconds(45))
  }

  @Test func retryAfterIsNeverClampedByMaxDelay() {
    // GitHub's Retry-After is authoritative; clamping it to maxDelay would retry too early.
    #expect(
      Self.noJitter.delay(forAttempt: 1, retryAfter: .seconds(300), random: Self.lowest)
        == .seconds(300)
    )
  }

  @Test func retryAfterJittersOnlyUpward() {
    let policy = RetryPolicy(
      maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(30), jitter: 0.5, multiplier: 2
    )
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(10), random: Self.lowest) == .seconds(10))
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(10), random: Self.highest) == .seconds(15))
    for _ in 0..<200 {
      let sample = policy.delay(forAttempt: 1, retryAfter: .seconds(10))
      #expect(sample >= .seconds(10) && sample <= .seconds(15))
    }
  }

  @Test func nonPositiveRetryAfterFallsBackToBackoff() {
    #expect(Self.noJitter.delay(forAttempt: 3, retryAfter: .zero, random: Self.lowest) == .seconds(4))
  }

  @Test func jitterIsClampedToUnitRange() {
    let policy = RetryPolicy(baseDelay: .seconds(4), maxDelay: .seconds(60), jitter: 5, multiplier: 1)
    #expect(policy.delay(forAttempt: 1, random: Self.lowest) == .zero)
    #expect(policy.delay(forAttempt: 1, random: Self.highest) == .seconds(8))
  }

  @Test func zeroBaseDelayNeverSleeps() {
    let policy = RetryPolicy(baseDelay: .zero, maxDelay: .seconds(10), jitter: 0.5, multiplier: 2)
    #expect(policy.delay(forAttempt: 4) == .zero)
  }

  @Test func shippedPoliciesAreSane() {
    #expect(RetryPolicy.github.maxDelay == .seconds(60))
    #expect(RetryPolicy.local.maxAttempts == 4)
  }
}

private struct TestFailure: Error, Equatable {
  let attempt: Int
}

@Suite struct RetryPolicyRunTests {
  static let policy = RetryPolicy(
    maxAttempts: 4, baseDelay: .seconds(1), maxDelay: .seconds(10), jitter: 0, multiplier: 2
  )
  static let lowest: @Sendable (ClosedRange<Double>) -> Double = { $0.lowerBound }

  @Test func returnsImmediatelyOnSuccess() async throws {
    var slept: [Duration] = []
    var calls = 0
    let value = try await Self.policy.run(
      sleep: { slept.append($0) }, random: Self.lowest
    ) {
      calls += 1
      return 42
    }
    #expect(value == 42)
    #expect(calls == 1)
    #expect(slept.isEmpty)
  }

  @Test func retriesUntilSuccessAndSleepsTheComputedSchedule() async throws {
    var slept: [Duration] = []
    var calls = 0
    let value = try await Self.policy.run(sleep: { slept.append($0) }, random: Self.lowest) {
      calls += 1
      if calls < 3 { throw TestFailure(attempt: calls) }
      return "ok"
    }
    #expect(value == "ok")
    #expect(calls == 3)
    #expect(slept == [.seconds(1), .seconds(2)])
  }

  @Test func stopsAtMaxAttemptsAndRethrowsTheLastError() async {
    var slept: [Duration] = []
    var calls = 0
    await #expect(throws: TestFailure(attempt: 4)) {
      try await Self.policy.run(sleep: { slept.append($0) }, random: Self.lowest) {
        calls += 1
        throw TestFailure(attempt: calls)
      }
    }
    #expect(calls == 4)
    #expect(slept == [.seconds(1), .seconds(2), .seconds(4)])
  }

  @Test func doesNotRetryWhenShouldRetryDeclines() async {
    var calls = 0
    await #expect(throws: TestFailure(attempt: 1)) {
      try await Self.policy.run(
        sleep: { _ in }, random: Self.lowest, shouldRetry: { _ in false }
      ) {
        calls += 1
        throw TestFailure(attempt: calls)
      }
    }
    #expect(calls == 1)
  }

  @Test func honoursPerErrorRetryAfter() async {
    var slept: [Duration] = []
    var calls = 0
    await #expect(throws: GitHubControlError.self) {
      try await Self.policy.run(
        sleep: { slept.append($0) },
        random: Self.lowest,
        retryAfter: { ($0 as? GitHubControlError)?.retryAfter }
      ) {
        calls += 1
        throw GitHubControlError.rateLimited(retryAfter: .seconds(90))
      }
    }
    #expect(slept == [.seconds(90), .seconds(90), .seconds(90)])
  }

  @Test func cancellationErrorsAreNeverRetried() async {
    var calls = 0
    await #expect(throws: CancellationError.self) {
      try await Self.policy.run(sleep: { _ in }, random: Self.lowest) {
        calls += 1
        throw CancellationError()
      }
    }
    #expect(calls == 1)
  }
}
