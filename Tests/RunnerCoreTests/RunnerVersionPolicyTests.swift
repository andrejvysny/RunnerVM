import Foundation
import RunnerCore
import Testing

@Suite struct RunnerVersionPolicyTests {
  static let now = Date(timeIntervalSince1970: 1_756_000_000)

  static func release(_ version: String, daysAgo: Double) -> RunnerRelease {
    RunnerRelease(version: version, publishedAt: now.addingTimeInterval(-daysAgo * 86_400))
  }

  /// One release, also the latest — the shape most existing tests need.
  static func history(_ version: String, daysAgo: Double) -> RunnerReleaseHistory {
    let release = Self.release(version, daysAgo: daysAgo)
    return RunnerReleaseHistory(releases: [release], latest: release)
  }

  static func evaluate(
    _ imageVersion: String?, _ history: RunnerReleaseHistory?
  ) -> RunnerVersionHealth {
    RunnerVersionPolicy.evaluate(imageVersion: imageVersion, history: history, now: now)
  }

  @Test func anImageWithNoRecordedRunnerVersionIsUnknown() {
    #expect(Self.evaluate(nil, Self.history("2.336.0", daysAgo: 90)) == .unknown)
  }

  @Test func nothingIsKnownUntilTheLatestReleaseHasBeenRead() {
    #expect(Self.evaluate("2.320.0", nil) == .unknown)
  }

  @Test func anEmptyHistoryIsUnknown() {
    #expect(Self.evaluate("2.320.0", RunnerReleaseHistory(releases: [], latest: nil)) == .unknown)
  }

  @Test(arguments: ["", "  ", "latest", "2.x.0", "2.336.0-beta", "1.2.3.4", "２.３"])
  func anUnparsableImageVersionIsUnknown(version: String) {
    #expect(Self.evaluate(version, Self.history("2.336.0", daysAgo: 90)) == .unknown)
  }

  @Test func anUnparsableLatestVersionIsUnknown() {
    #expect(Self.evaluate("2.320.0", Self.history("nightly", daysAgo: 90)) == .unknown)
  }

  @Test func matchingTheLatestReleaseIsHealthy() {
    #expect(Self.evaluate("2.336.0", Self.history("2.336.0", daysAgo: 90)) == .healthy)
  }

  @Test func aVersionAheadOfTheLatestReleaseIsHealthy() {
    #expect(Self.evaluate("2.337.0", Self.history("2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("3.0.0", Self.history("2.336.0", daysAgo: 90)) == .healthy)
  }

  @Test func aLeadingVOnEitherSideIsTolerated() {
    #expect(Self.evaluate("v2.336.0", Self.history("v2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("v2.335.0", Self.history("2.336.0", daysAgo: 1)) == .stale)
  }

  @Test func missingComponentsCountAsZero() {
    #expect(Self.evaluate("2.336", Self.history("2.336.0", daysAgo: 90)) == .healthy)
    #expect(Self.evaluate("2.336", Self.history("2.336.1", daysAgo: 1)) == .stale)
  }

  @Test func beingBehindInsideTheGraceWindowIsOnlyStale() {
    #expect(Self.evaluate("2.320.0", Self.history("2.336.0", daysAgo: 0)) == .stale)
    #expect(Self.evaluate("2.320.0", Self.history("2.336.0", daysAgo: 29)) == .stale)
  }

  /// The boundary itself is `tooOld`: GitHub's window is "within 30 days", so day 30 is over.
  @Test func exactlyThirtyDaysAfterTheReleaseIsTooOld() {
    let boundary = Self.history("2.336.0", daysAgo: Double(RunnerVersionPolicy.graceDays))
    #expect(Self.evaluate("2.320.0", boundary) == .tooOld)
    let justInsideRelease = RunnerRelease(
      version: "2.336.0",
      publishedAt: boundary.latest!.publishedAt.addingTimeInterval(1))
    let justInside = RunnerReleaseHistory(releases: [justInsideRelease], latest: justInsideRelease)
    #expect(Self.evaluate("2.320.0", justInside) == .stale)
  }

  @Test func longPastTheGraceWindowIsTooOld() {
    #expect(Self.evaluate("2.300.0", Self.history("2.336.0", daysAgo: 365)) == .tooOld)
  }

  /// A release timestamp in the future (a skewed host clock) must not read as `tooOld`.
  @Test func aFutureReleaseTimestampIsStaleNotTooOld() {
    #expect(Self.evaluate("2.320.0", Self.history("2.336.0", daysAgo: -5)) == .stale)
  }

  @Test func majorMinorPatchAreComparedNumericallyNotLexically() {
    #expect(Self.evaluate("2.9.0", Self.history("2.10.0", daysAgo: 1)) == .stale)
    #expect(Self.evaluate("2.100.0", Self.history("2.99.0", daysAgo: 1)) == .healthy)
  }

  // MARK: - The clock is measured from the first missed release, not the latest (the regression)

  /// A release the image is already ahead of does not count, and a release published *before* the
  /// image's own version must never be mistaken for what it missed.
  @Test func aNewerReleaseDoesNotResetTheGraceWindow() {
    let history = RunnerReleaseHistory(
      releases: [
        Self.release("2.330.0", daysAgo: 40), // the first release 2.320.0 missed
        Self.release("2.331.0", daysAgo: 1), // latest — published long after, must not reset it
      ],
      latest: Self.release("2.331.0", daysAgo: 1))
    // Old bug: measured from latest (1 day) -> `stale`. Correct: from first missed (40 days).
    #expect(Self.evaluate("2.320.0", history) == .tooOld)
  }

  @Test func firstMissedReleaseFindsTheOldestReleaseAheadOfTheImage() {
    let history = RunnerReleaseHistory(
      releases: [
        Self.release("2.330.0", daysAgo: 40),
        Self.release("2.331.0", daysAgo: 1),
      ],
      latest: Self.release("2.331.0", daysAgo: 1))
    let missed = RunnerVersionPolicy.firstMissedRelease(imageVersion: "2.320.0", history: history)
    #expect(missed?.version == "2.330.0")
  }

  @Test func firstMissedReleaseIsNilOnceHealthy() {
    let missed = RunnerVersionPolicy.firstMissedRelease(
      imageVersion: "2.336.0", history: Self.history("2.336.0", daysAgo: 90))
    #expect(missed == nil)
  }

  @Test func firstMissedReleaseIgnoresUnparsableTags() {
    let history = RunnerReleaseHistory(
      releases: [
        RunnerRelease(version: "nightly", publishedAt: Self.now.addingTimeInterval(-1 * 86_400)),
        Self.release("2.331.0", daysAgo: 40),
      ],
      latest: Self.release("2.331.0", daysAgo: 40))
    let missed = RunnerVersionPolicy.firstMissedRelease(imageVersion: "2.320.0", history: history)
    #expect(missed?.version == "2.331.0")
  }

  @Test func healthRoundTripsThroughItsRawValue() throws {
    for health in RunnerVersionHealth.allCases {
      let encoded = try JSONEncoder().encode([health])
      #expect(try JSONDecoder().decode([RunnerVersionHealth].self, from: encoded) == [health])
    }
    #expect(RunnerVersionHealth(rawValue: "tooOld") == .tooOld)
  }
}
