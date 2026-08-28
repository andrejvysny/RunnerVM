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

/// One published `actions/runner` release: version without the leading `v`, and when GitHub
/// published it — the clock the grace window is measured from.
public struct RunnerRelease: Codable, Sendable, Equatable {
  public var version: String
  public var publishedAt: Date

  public init(version: String, publishedAt: Date) {
    self.version = version
    self.publishedAt = publishedAt
  }
}

/// Prior name, kept so call sites that only ever cared about "the newest release" do not have to
/// churn.
public typealias LatestRunnerRelease = RunnerRelease

/// A bounded, newest-first window of recent `actions/runner` releases, plus the highest version
/// among them. `RunnerVersionPolicy` needs the whole window — not just `latest` — because the
/// 30-day grace clock is measured from the first release an image missed, not from whichever
/// release happens to be newest today (spec §53).
public struct RunnerReleaseHistory: Codable, Sendable, Equatable {
  /// Newest first by `publishedAt`.
  public var releases: [RunnerRelease]
  /// Highest semantic version among `releases`; not necessarily `releases.first`, since GitHub
  /// does not guarantee publication order tracks version order.
  public var latest: RunnerRelease?

  public init(releases: [RunnerRelease], latest: RunnerRelease?) {
    self.releases = releases
    self.latest = latest
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

  /// The grace window is measured from the *first* release the image fell behind on, not from
  /// whatever GitHub has published most recently: a new release must never reset the clock on an
  /// image that has already been behind for weeks.
  public static func evaluate(
    imageVersion: String?, history: RunnerReleaseHistory?, now: Date
  ) -> RunnerVersionHealth {
    guard let history, !history.releases.isEmpty,
          let image = SemanticVersion(imageVersion),
          let latest = history.latest.flatMap({ SemanticVersion($0.version) })
    else { return .unknown }
    guard image < latest else { return .healthy }
    guard let firstMissed = firstMissedRelease(imageVersion: imageVersion, history: history)
    else { return .healthy }
    return now.timeIntervalSince(firstMissed.publishedAt) < graceInterval ? .stale : .tooOld
  }

  /// The oldest published release newer than `imageVersion` — the release whose publication date
  /// the grace window is measured from. `nil` once the image is at or ahead of every known
  /// release, or when either side fails to parse. Releases whose tag does not parse as a semantic
  /// version are ignored rather than treated as missed.
  public static func firstMissedRelease(
    imageVersion: String?, history: RunnerReleaseHistory?
  ) -> RunnerRelease? {
    guard let history, let image = SemanticVersion(imageVersion) else { return nil }
    return history.releases
      .filter { release in SemanticVersion(release.version).map { image < $0 } ?? false }
      .min { $0.publishedAt < $1.publishedAt }
  }
}

/// `major.minor.patch` with a tolerated leading `v` and an optional `-suffix`. Missing components
/// count as zero, so `2.336` and `2.336.0` compare equal; anything that is not a dotted run of
/// digits is unparsable, which the policy reports as `unknown` rather than guessing.
///
/// `public`: `GitHubControl` reuses this exact comparison to pick `RunnerReleaseHistory.latest` by
/// true version rather than by publish date, and `HostSetup` reuses it to decide whether a release
/// is newer than the installed build — three readers that must never disagree about ordering.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  let parts: [Int]
  /// Everything after the first `-`, empty for a plain release. `actions/runner` never publishes
  /// one; RunnerVM's own tags may (`v0.3.0-rc1`), and `runnerctl upgrade` compares those.
  public let suffix: String

  public var major: Int { parts[0] }
  public var minor: Int { parts[1] }
  public var patch: Int { parts[2] }

  public init(major: Int, minor: Int, patch: Int, suffix: String = "") {
    parts = [major, minor, patch]
    self.suffix = suffix
  }

  /// Strict: a pre-release suffix makes the string unparsable. `actions/runner` never publishes
  /// one, and the health policy deliberately reports something it does not recognise as `unknown`
  /// rather than guessing which side of a release a `-beta` build falls on.
  public init?(_ raw: String?) { self.init(raw, allowingSuffix: false) }

  /// Lenient: a RunnerVM release tag may carry `-rc1`, and `runnerctl upgrade` has to order it
  /// against the plain release.
  public init?(tag raw: String?) { self.init(raw, allowingSuffix: true) }

  private init?(_ raw: String?, allowingSuffix: Bool) {
    guard var text = raw.map({ $0.trimmingCharacters(in: .whitespaces) }), !text.isEmpty else {
      return nil
    }
    if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
    var tail = ""
    if allowingSuffix, let dash = text.firstIndex(of: "-") {
      tail = String(text[text.index(after: dash)...])
      text = String(text[..<dash])
    }
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
    suffix = tail
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    for (left, right) in zip(lhs.parts, rhs.parts) where left != right { return left < right }
    // A pre-release of X.Y.Z precedes the release itself; two suffixes order lexically, which is
    // right for rc1 < rc2 and admittedly arbitrary for anything else.
    if lhs.suffix == rhs.suffix { return false }
    if lhs.suffix.isEmpty { return false }
    if rhs.suffix.isEmpty { return true }
    return lhs.suffix < rhs.suffix
  }

  public var description: String {
    "\(major).\(minor).\(patch)" + (suffix.isEmpty ? "" : "-\(suffix)")
  }
}
