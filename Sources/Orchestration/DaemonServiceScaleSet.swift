import DaemonAPI
import Foundation
import GitHubControl
import Persistence
import RunnerCore

/// `scaleset.list` and `debug.demandSet` (spec §14, §13).
///
/// Split out of `DaemonServiceImpl.swift` to keep that file under its line budget; every member
/// runs actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  func scaleSetList() async throws -> ScaleSetListResponse {
    guard let orchestrator else {
      throw DaemonServiceError.unavailable(reason: "the orchestrator is not running")
    }
    let names = Dictionary(
      try await profiles.list().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let reports = await orchestrator.demandReport()
    return ScaleSetListResponse(
      scaleSets: reports
        .map { Self.summary($0, profile: names[$0.profileId] ?? $0.profileId.rawValue) }
        .sorted { $0.profile < $1.profile })
  }

  func debugDemandSet(_ request: DebugDemandSetRequest) async throws -> DebugDemandSetResponse {
    guard let orchestrator else {
      throw DaemonServiceError.unavailable(reason: "the orchestrator is not running")
    }
    let id = try await profileID(named: request.profile)
    try await orchestrator.setManualDemand(profile: id, assignedJobs: request.assignedJobs)
    logger.notice(
      "demand overridden",
      metadata: [
        "profile": .string(request.profile),
        "assigned_jobs": .stringConvertible(request.assignedJobs),
      ])
    return DebugDemandSetResponse(
      profile: request.profile, assignedJobs: max(0, request.assignedJobs))
  }

  func debugScaleSetReconnect(
    _ request: DebugScaleSetReconnectRequest
  ) async throws -> DebugScaleSetReconnectResponse {
    guard let orchestrator else {
      throw DaemonServiceError.unavailable(reason: "the orchestrator is not running")
    }
    let id = try await profileID(named: request.profile)
    try await orchestrator.forceScaleSetReconnect(profile: id)
    logger.notice(
      "scale set reconnect forced", metadata: ["profile": .string(request.profile)])
    return DebugScaleSetReconnectResponse(profile: request.profile)
  }

  static func summary(_ report: DemandProviderReport, profile: String) -> ScaleSetSummary {
    ScaleSetSummary(
      profile: profile,
      name: report.scaleSetName,
      githubScaleSetId: report.githubScaleSetId,
      state: report.state,
      sessionState: report.sessionState,
      sessionGeneration: report.sessionGeneration,
      lastMessageId: report.lastMessageId,
      advertisedCapacity: report.advertisedCapacity,
      assignedJobs: report.snapshot.assignedJobs,
      healthy: report.snapshot.healthy,
      statistics: report.snapshot.statistics.map(Self.statistics),
      updatedAt: RFC3339.string(from: report.snapshot.updatedAt),
      lastError: report.lastError)
  }

  private static func statistics(_ value: ScaleSetStatistics) -> ScaleSetStatisticsDTO {
    ScaleSetStatisticsDTO(
      totalAvailableJobs: value.totalAvailableJobs,
      totalAcquiredJobs: value.totalAcquiredJobs,
      totalAssignedJobs: value.totalAssignedJobs,
      totalRunningJobs: value.totalRunningJobs,
      totalRegisteredRunners: value.totalRegisteredRunners,
      totalBusyRunners: value.totalBusyRunners,
      totalIdleRunners: value.totalIdleRunners)
  }
}
