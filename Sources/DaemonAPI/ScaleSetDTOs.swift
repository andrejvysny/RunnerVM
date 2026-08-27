import Foundation

/// `ScaleSetStatistics` flattened for the wire. DaemonAPI deliberately does not depend on
/// GitHubControl: `runnerctl` must be linkable without the GitHub client.
public struct ScaleSetStatisticsDTO: Codable, Sendable, Hashable {
  public var totalAvailableJobs: Int64
  public var totalAcquiredJobs: Int64
  public var totalAssignedJobs: Int64
  public var totalRunningJobs: Int64
  public var totalRegisteredRunners: Int64
  public var totalBusyRunners: Int64
  public var totalIdleRunners: Int64

  public init(
    totalAvailableJobs: Int64 = 0, totalAcquiredJobs: Int64 = 0, totalAssignedJobs: Int64 = 0,
    totalRunningJobs: Int64 = 0, totalRegisteredRunners: Int64 = 0, totalBusyRunners: Int64 = 0,
    totalIdleRunners: Int64 = 0
  ) {
    self.totalAvailableJobs = totalAvailableJobs
    self.totalAcquiredJobs = totalAcquiredJobs
    self.totalAssignedJobs = totalAssignedJobs
    self.totalRunningJobs = totalRunningJobs
    self.totalRegisteredRunners = totalRegisteredRunners
    self.totalBusyRunners = totalBusyRunners
    self.totalIdleRunners = totalIdleRunners
  }
}

/// One profile's scale set as the daemon currently sees it (spec §14, §45). The message-session
/// bearer token has no field here and never will: it is not persisted either.
public struct ScaleSetSummary: Codable, Sendable, Hashable {
  public var profile: String
  /// `runnervm-<profile>`, absent until the scale set has been registered.
  public var name: String?
  public var githubScaleSetId: Int64?
  /// `planned`, `ready`, `failed` or `manual` when no scale set backs this profile.
  public var state: String
  /// `open`, `closed` or `-`.
  public var sessionState: String
  public var sessionGeneration: Int?
  /// Message-queue cursor: the highest acknowledged message id in this generation.
  public var lastMessageId: Int64?
  /// What the next poll reports as `X-ScaleSetMaxCapacity`.
  public var advertisedCapacity: Int
  public var assignedJobs: Int
  public var healthy: Bool
  public var statistics: ScaleSetStatisticsDTO?
  public var updatedAt: String?
  public var lastError: String?

  public init(
    profile: String, name: String? = nil, githubScaleSetId: Int64? = nil, state: String,
    sessionState: String = "-", sessionGeneration: Int? = nil, lastMessageId: Int64? = nil,
    advertisedCapacity: Int = 0, assignedJobs: Int = 0, healthy: Bool = true,
    statistics: ScaleSetStatisticsDTO? = nil, updatedAt: String? = nil, lastError: String? = nil
  ) {
    self.profile = profile
    self.name = name
    self.githubScaleSetId = githubScaleSetId
    self.state = state
    self.sessionState = sessionState
    self.sessionGeneration = sessionGeneration
    self.lastMessageId = lastMessageId
    self.advertisedCapacity = advertisedCapacity
    self.assignedJobs = assignedJobs
    self.healthy = healthy
    self.statistics = statistics
    self.updatedAt = updatedAt
    self.lastError = lastError
  }
}

public struct ScaleSetListResponse: Codable, Sendable, Hashable {
  public var scaleSets: [ScaleSetSummary]

  public init(scaleSets: [ScaleSetSummary]) { self.scaleSets = scaleSets }
}

/// `debug.demandSet` — accepted only while the daemon runs the manual demand provider.
public struct DebugDemandSetRequest: Codable, Sendable, Hashable {
  public var profile: String
  public var assignedJobs: Int

  public init(profile: String, assignedJobs: Int) {
    self.profile = profile
    self.assignedJobs = assignedJobs
  }
}

public struct DebugDemandSetResponse: Codable, Sendable, Hashable {
  public var profile: String
  public var assignedJobs: Int

  public init(profile: String, assignedJobs: Int) {
    self.profile = profile
    self.assignedJobs = assignedJobs
  }
}

/// `debug.scaleSetReconnect` — drops the profile's current message session and forces a fresh one
/// with a new generation, exactly as an unexpected connection drop would. Accepted only while the
/// profile's demand comes from a registered GitHub scale set.
public struct DebugScaleSetReconnectRequest: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}

public struct DebugScaleSetReconnectResponse: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}
