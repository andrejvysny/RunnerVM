import Foundation
import RunnerCore
import Testing

@Suite struct RunnerVersionPolicyTests {
  static let now = Date(timeIntervalSince1970: 1_756_000_000)

  static func release(_ version: String, daysAgo: Double) -> LatestRunnerRelease {
    LatestRunnerRelease(version: version, publishedAt: now.addingTimeInterval(-daysAgo * 86_400))
  }

  static func evaluate(
    _ imageVersion: String?, _ latest: LatestRunnerRelease?
  ) -> RunnerVersionHealth {
    RunnerVersionPolicy.evaluate(imageVersion: imageVersion, latest: latest, now: now)
  }

  @Test func anImageWithNoRecordedRunnerVersionIsUnknown() {
    #expect(Self.evaluate(nil, Self.release("2.336.0", daysAgo: 90)) == .unknown)
  }

  @Test func nothingIsKnownUntilTheLatestReleaseHasBeenRead() {
    #expect(Self.evaluate("2.320.0", nil) == .unknown)
  }

  @Test(arguments: ["", "  ", "latest", "2.x.0", "2.336.0-beta", "1.2.3.4", "２.３"])
  func anUnparsableImageVersionIsUnknown(version: String) {
    #expect(Self.evaluate(version, Self.release("2.336.0", daysAgo: 90)) == .unknown)
  }

  @Test func anUnparsableLatestVersionIsUnknown() {
    #expect(Self.evaluate("2.320.0", Self.release("nightly", daysAgo: 90)) == .unknown)
  }

  @Test func matchingTheLatestReleaseIsHealthy() {
    #expect(Self.evaluate("2.336.0", Self.release("2.336.0", daysAgo: 90)) == .healthy)
  }

  @Test func aVersionAheadOfTheLatestReleaseIsHealthy() {
    #expect(Self.evaluate("2.337.0", Self.release("2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("3.0.0", Self.release("2.336.0", daysAgo: 90)) == .healthy)
  }

  @Test func aLeadingVOnEitherSideIsTolerated() {
    #expect(Self.evaluate("v2.336.0", Self.release("v2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("v2.335.0", Self.release("2.336.0", daysAgo: 1)) == .stale)
  }

  @Test func missingComponentsCountAsZero() {
    #expect(Self.evaluate("2.336", Self.release("2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("2.336", Self.release("2.336.1", daysAgo: 1)) == .stale)
  }

  @Test func beingBehindInsideTheGraceWindowIsOnlyStale() {
    #expect(Self.evaluate("2.320.0", Self.release("2.336.0", daysAgo: 0)) == .stale)
    #expect(Self.evaluate("2.320.0", Self.release("2.336.0", daysAgo: 29)) == .stale)
  }

  /// The boundary itself is `tooOld`: GitHub's window is "within 30 days", so day 30 is over.
  @Test func exactlyThirtyDaysAfterTheReleaseIsTooOld() {
    let boundary = Self.release("2.336.0", daysAgo: Double(RunnerVersionPolicy.graceDays))
    #expect(Self.evaluate("2.320.0", boundary) == .tooOld)
    let justInside = LatestRunnerRelease(
      version: "2.336.0",
      publishedAt: boundary.publishedAt.addingTimeInterval(1))
    #expect(Self.evaluate("2.320.0", justInside) == .stale)
  }

  @Test func longPastTheGraceWindowIsTooOld() {
    #expect(Self.evaluate("2.300.0", Self.release("2.336.0", daysAgo: 365)) == .tooOld)
  }

  /// A release timestamp in the future (a skewed host clock) must not read as `tooOld`.
  @Test func aFutureReleaseTimestampIsStaleNotTooOld() {
    #expect(Self.evaluate("2.320.0", Self.release("2.336.0", daysAgo: -5)) == .stale)
  }

  @Test func majorMinorPatchAreComparedNumericallyNotLexically() {
    #expect(Self.evaluate("2.9.0", Self.release("2.10.0", daysAgo: 1)) == .stale)
    #expect(Self.evaluate("2.100.0", Self.release("2.99.0", daysAgo: 1)) == .healthy)
  }

  @Test func healthRoundTripsThroughItsRawValue() throws {
    for health in RunnerVersionHealth.allCases {
      let encoded = try JSONEncoder().encode([health])
      #expect(try JSONDecoder().decode([RunnerVersionHealth].self, from: encoded) == [health])
    }
    #expect(RunnerVersionHealth(rawValue: "tooOld") == .tooOld)
  }
}
