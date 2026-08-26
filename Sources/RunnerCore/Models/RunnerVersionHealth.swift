import Foundation

/// Freshness of the `actions/runner` build baked into an image, relative to the newest release
/// GitHub has published (spec §53).
///
/// `unknown` is a first-class outcome, not an error: an image imported from a raw disk carries no
/// `runnerVersion`, and a daemon with no GitHub credential never learns what the latest release is.
public enum RunnerVersionHealth: String, Codable, Sendable, CaseIterable, Hashable {
  case healthy
  case stale
  case tooOld
  case unknown
}

/// The newest published `actions/runner` release: version without the leading `v`, and when GitHub
/// published it — the clock the grace window is measured from.
public struct LatestRunnerRelease: Codable, Sendable, Equatable {
  public var version: String
  public var publishedAt: Date

  public init(version: String, publishedAt: Date) {
    self.version = version
    self.publishedAt = publishedAt
  }
}

/// Turns an image's baked-in runner version into a health verdict.
///
/// Pure and clock-injected: the daemon, the CLI and the tests all reach the same verdict for the
/// same inputs, and nothing here reads the wall clock or the network.
public enum RunnerVersionPolicy {
  /// GitHub requires a self-hosted runner with automatic updates disabled to be updated within 30
  /// days of a release; past that window GitHub itself stops handing it jobs, so an image that far
  /// behind is `tooOld` rather than merely `stale`.
  public static let graceDays = 30

  public static var graceInterval: TimeInterval { Double(graceDays) * 86_400 }

  public static func evaluate(
    imageVersion: String?, latest: LatestRunnerRelease?, now: Date
  ) -> RunnerVersionHealth {
    guard let latest,
          let image = SemanticVersion(imageVersion),
          let published = SemanticVersion(latest.version)
    else { return .unknown }
    guard image < published else { return .healthy }
    return now.timeIntervalSince(latest.publishedAt) < graceInterval ? .stale : .tooOld
  }
}

/// `major.minor.patch` with a tolerated leading `v`. Missing components count as zero, so `2.336`
/// and `2.336.0` compare equal; anything that is not a dotted run of digits is unparsable, which
/// the policy reports as `unknown` rather than guessing.
struct SemanticVersion: Comparable {
  let parts: [Int]

  init?(_ raw: String?) {
    guard var text = raw.map({ $0.trimmingCharacters(in: .whitespaces) }), !text.isEmpty else {
      return nil
    }
    if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
    let fields = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(fields.count) else { return nil }
    var parsed: [Int] = []
    for field in fields {
      guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }),
            let value = Int(field)
      else { return nil }
      parsed.append(value)
    }
    parts = parsed + Array(repeating: 0, count: 3 - parsed.count)
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    for (left, right) in zip(lhs.parts, rhs.parts) where left != right { return left < right }
    return false
  }
}
