import Foundation
import GitHubControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Tracks the newest published `actions/runner` release and grades local images against it
/// (spec §53, §114).
///
/// Refreshed from the daemon's slow maintenance loop, not from a timer of its own: the loop
/// already ticks eagerly at startup and every five minutes after, so this only has to decide when
/// six hours have passed. The last known release survives a failed refresh — an image does not
/// become `unknown` because api.github.com blinked — and nothing here ever mutates an image.
public actor RunnerVersionMonitor {
  public struct Tuning: Sendable {
    /// Runner releases land every few weeks; six hours is far more often than the answer changes.
    public var refreshInterval: Duration = .seconds(6 * 3_600)
    /// Spread across hosts so a fleet restarted together does not query GitHub in lockstep.
    public var jitter: Duration = .seconds(900)
    /// Retry cadence while GitHub is unreachable. Shorter than `refreshInterval` so a transient
    /// outage does not cost a full six hours of freshness.
    public var failureBackoff: Duration = .seconds(900)

    public init() {}
  }

  /// Why `latest()` is still `nil`, phrased for `runnerctl doctor`.
  public enum Unavailable: Sendable, Equatable {
    case notConfigured
    case notFetchedYet
    case lastAttemptFailed(reason: String)

    public var detail: String {
      switch self {
      case .notConfigured: "no GitHub credential is configured"
      case .notFetchedYet: "the latest runner release has not been fetched yet"
      case let .lastAttemptFailed(reason): "the last GitHub lookup failed (\(reason))"
      }
    }
  }

  private let gateway: GitHubGateway
  private let tuning: Tuning
  private let now: @Sendable () -> Date
  private let logger: Logger

  private var cached: LatestRunnerRelease?
  private var nextAttemptAt: Date?
  private var failureStreak = 0
  private var lastFailure: String?

  public init(
    gateway: GitHubGateway, tuning: Tuning = Tuning(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .github)
  ) {
    self.gateway = gateway
    self.tuning = tuning
    self.now = now
    self.logger = logger
  }

  // MARK: - Refresh

  /// The maintenance-loop entry point: refreshes only once the interval (or the failure backoff)
  /// has elapsed, so it can be called on every tick.
  @discardableResult
  public func refreshIfDue() async -> LatestRunnerRelease? {
    guard let due = nextAttemptAt else { return await refresh() }
    guard now() >= due else { return cached }
    return await refresh()
  }

  /// One lookup. Never throws: a missing credential or a failed call leaves the last known release
  /// in place, and every image grades `unknown` only while nothing has ever been fetched.
  @discardableResult
  public func refresh() async -> LatestRunnerRelease? {
    guard let api = await gateway.runnersAPI() else {
      // Not a failure: there is simply no credential to ask with. Re-checked next tick, cheaply.
      nextAttemptAt = now().addingTimeInterval(seconds(tuning.failureBackoff))
      return cached
    }
    do {
      let release = try await api.latestRunnerRelease()
      if release != cached {
        logger.info(
          "latest actions/runner release",
          metadata: [
            "version": .string(release.version),
            "published_at": .string(ISO8601DateFormatter().string(from: release.publishedAt)),
          ])
      }
      cached = release
      failureStreak = 0
      lastFailure = nil
      nextAttemptAt = now().addingTimeInterval(nextDelay())
      return release
    } catch {
      recordFailure(error)
      return cached
    }
  }

  /// One warning per failure streak, not one per attempt: an unreachable GitHub must not fill the
  /// log at the maintenance loop's cadence.
  private func recordFailure(_ error: any Error) {
    let reason = Self.describe(error)
    failureStreak += 1
    lastFailure = reason
    if failureStreak == 1 {
      logger.warning(
        "could not read the latest actions/runner release; keeping the last known value",
        metadata: [
          "error": .string(reason),
          "known_version": .string(cached?.version ?? "-"),
        ])
    }
    nextAttemptAt = now().addingTimeInterval(seconds(tuning.failureBackoff))
  }

  private func nextDelay() -> TimeInterval {
    let base = seconds(tuning.refreshInterval)
    let spread = seconds(tuning.jitter)
    guard spread > 0 else { return base }
    return max(1, base + Double.random(in: -spread...spread))
  }

  private func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds)
  }

  // MARK: - Queries

  public func latest() -> LatestRunnerRelease? { cached }

  public func health(for metadata: ImageMetadata) -> RunnerVersionHealth {
    health(forVersion: metadata.runnerVersion)
  }

  public func health(forVersion version: String?) -> RunnerVersionHealth {
    RunnerVersionPolicy.evaluate(imageVersion: version, latest: cached, now: now())
  }

  /// `nil` once a release is known. Drives the `runner-version` doctor check's explanation.
  public func unavailable() async -> Unavailable? {
    guard cached == nil else { return nil }
    if let lastFailure { return .lastAttemptFailed(reason: lastFailure) }
    return await gateway.runnersAPI() == nil ? .notConfigured : .notFetchedYet
  }

  /// Seconds since GitHub published the newest release, for
  /// `runnervm_runner_latest_release_age_seconds`. `nil` while nothing is known.
  public func releaseAgeSeconds() -> Double? {
    cached.map { max(0, now().timeIntervalSince($0.publishedAt)) }
  }

  private static func describe(_ error: any Error) -> String {
    guard let error = error as? any RunnerError else { return String(describing: error) }
    return "\(error.code): \(error.message)"
  }
}
