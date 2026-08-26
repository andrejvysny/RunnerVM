import Foundation
import GitHubControl
import RunnerCore

/// What the demand side of the world currently says about one profile (spec §13).
///
/// `assignedJobs` is the only number the scheduler is allowed to plan from. It comes from GitHub's
/// own statistics, never from counting queue messages: a redelivered message would otherwise
/// inflate demand that GitHub already considers served.
public struct DemandSnapshot: Sendable, Equatable {
  public var assignedJobs: Int
  /// The last full statistics block, when the provider has one. `nil` for the manual provider.
  public var statistics: ScaleSetStatistics?
  public var updatedAt: Date
  /// False while the provider cannot talk to GitHub for this profile. The scheduler keeps the
  /// last known demand rather than scaling to zero on a transient outage (spec §135).
  public var healthy: Bool

  public init(
    assignedJobs: Int = 0, statistics: ScaleSetStatistics? = nil, updatedAt: Date = Date(),
    healthy: Bool = true
  ) {
    self.assignedJobs = assignedJobs
    self.statistics = statistics
    self.updatedAt = updatedAt
    self.healthy = healthy
  }
}

/// Everything the orchestrator can learn from a demand provider (spec §118).
public enum DemandEvent: Sendable, Equatable {
  case demandChanged(profile: RunnerProfileID)
  case jobStarted(profile: RunnerProfileID, runnerName: String, requestId: Int64)
  case jobCompleted(
    profile: RunnerProfileID, runnerName: String, requestId: Int64, result: String?)
  case providerDegraded(profile: RunnerProfileID, reason: String)

  public var profile: RunnerProfileID {
    switch self {
    case let .demandChanged(profile): profile
    case let .jobStarted(profile, _, _): profile
    case let .jobCompleted(profile, _, _, _): profile
    case let .providerDegraded(profile, _): profile
    }
  }
}

/// One provider-tracked profile, flattened for `scaleset.list`. Everything here is safe to log:
/// the message-session bearer token is deliberately absent (`ScaleSetSessionInfo` has none either).
public struct DemandProviderReport: Sendable {
  public var profileId: RunnerProfileID
  public var scaleSetName: String?
  public var githubScaleSetId: Int64?
  /// `ScaleSetRecord.state` — free text owned by the provider (`planned`, `ready`, `failed`).
  public var state: String
  /// `open`, `closed` or `-` when no session has been opened yet.
  public var sessionState: String
  public var sessionGeneration: Int?
  public var lastMessageId: Int64?
  public var advertisedCapacity: Int
  public var snapshot: DemandSnapshot
  public var lastError: String?

  public init(
    profileId: RunnerProfileID, scaleSetName: String? = nil, githubScaleSetId: Int64? = nil,
    state: String, sessionState: String = "-", sessionGeneration: Int? = nil,
    lastMessageId: Int64? = nil, advertisedCapacity: Int = 0,
    snapshot: DemandSnapshot = DemandSnapshot(), lastError: String? = nil
  ) {
    self.profileId = profileId
    self.scaleSetName = scaleSetName
    self.githubScaleSetId = githubScaleSetId
    self.state = state
    self.sessionState = sessionState
    self.sessionGeneration = sessionGeneration
    self.lastMessageId = lastMessageId
    self.advertisedCapacity = advertisedCapacity
    self.snapshot = snapshot
    self.lastError = lastError
  }
}

/// Spec §13. The scheduler must not be able to tell which implementation is behind this, which is
/// why capacity advertisement is a provider call rather than a scale-set-shaped API on the side.
public protocol DemandProvider: Sendable {
  func start() async throws
  func stop() async

  /// Single-consumer: the orchestrator owns the iteration. Repeated reads return the same stream.
  var events: AsyncStream<DemandEvent> { get async }

  func snapshot(profile: RunnerProfileID) async -> DemandSnapshot

  /// What the next poll reports as `X-ScaleSetMaxCapacity` (spec §109). Providers with no wire
  /// protocol simply remember it so `scaleset.list` can show it.
  func advertise(profile: RunnerProfileID, capacity: Int) async

  /// Picks up profiles added by a `config.apply` since the last pass. Cheap and idempotent.
  func refresh() async

  func report() async -> [DemandProviderReport]

  /// `debug.demandSet`. Only the manual provider accepts it — with a scale set in front, demand is
  /// GitHub's statistics and nothing else.
  func setDemand(profile: RunnerProfileID, assignedJobs: Int) async throws
}

public extension DemandProvider {
  func refresh() async {}

  func setDemand(profile: RunnerProfileID, assignedJobs: Int) async throws {
    throw OrchestrationError.demandNotManual
  }
}

/// Spec §14: one profile ⇒ one scale set, named after the profile so an operator reading the
/// GitHub UI can map a scale set back to a `runnerctl profile show` in one step.
public enum ScaleSetNaming {
  public static let prefix = "runnervm-"

  public static func name(profile: String) -> String { prefix + profile }
}

