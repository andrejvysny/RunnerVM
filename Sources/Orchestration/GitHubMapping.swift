import DaemonAPI
import Foundation
import GitHubControl
import Persistence
import RunnerCore

/// `github_scopes` / `runner_sessions` rows -> daemon API DTOs, and the one place a persisted
/// scope row is turned back into a `GitHubScope`.
enum GitHubMapping {
  /// Health values `github_scopes.health` may hold. The column is free text in the schema, so the
  /// vocabulary is asserted here rather than by SQLite.
  static let healthy = GitHubScopeHealth.Status.healthy.rawValue

  static func scope(_ record: GitHubScopeRecord) throws -> GitHubScope {
    switch record.kind {
    case .organization:
      return .organization(owner: record.owner, runnerGroupID: record.runnerGroupId)
    case .repository:
      guard let repository = record.repository, !repository.isEmpty else {
        throw GitHubControlError.permanentConfiguration(
          reason: "scope '\(record.name)' is a repository scope with no repository name")
      }
      return .repository(owner: record.owner, repository: repository)
    }
  }

  static func scopeSlug(_ record: GitHubScopeRecord) -> String {
    (try? scope(record).slug) ?? record.owner
  }

  /// `status` is the live probe; `schedulable` is the persisted decision the scheduler acts on,
  /// which deliberately lags a transient outage (spec §135).
  static func scopeHealth(
    _ record: GitHubScopeRecord, probe: GitHubScopeHealth?
  ) -> ScopeHealthDTO {
    ScopeHealthDTO(
      name: record.name,
      slug: scopeSlug(record),
      kind: record.kind.rawValue,
      status: probe?.status.rawValue ?? record.health,
      runnerGroup: record.runnerGroupName,
      runnerGroupId: record.runnerGroupId,
      visibility: probe?.visibility?.visibility,
      isPublicRepository: probe?.visibility?.isPublic ?? record.isPublicRepository,
      runnerCount: probe?.runnerCount,
      schedulable: record.enabled && record.health == healthy,
      problems: (probe?.problems ?? []).map {
        ScopeProblemDTO(code: $0.code, errorClass: $0.errorClass?.rawValue, detail: $0.detail)
      })
  }

  static func session(_ record: RunnerSessionRecord, profile: String) -> RunnerSessionDTO {
    RunnerSessionDTO(
      id: record.id.rawValue,
      instanceId: record.instanceId.rawValue,
      profile: profile,
      jitSource: record.jitSource.rawValue,
      state: record.state.rawValue,
      githubRunnerId: record.githubRunnerId,
      githubRunnerName: record.githubRunnerName,
      result: record.result,
      failureCode: record.failureCode,
      createdAt: RFC3339.string(from: record.createdAt.date),
      jitIssuedAt: record.jitIssuedAt.map { RFC3339.string(from: $0.date) },
      jitDeliveredAt: record.jitDeliveredAt.map { RFC3339.string(from: $0.date) },
      runnerStartedAt: record.runnerStartedAt.map { RFC3339.string(from: $0.date) },
      runnerOnlineAt: record.runnerOnlineAt.map { RFC3339.string(from: $0.date) },
      jobStartedAt: record.jobStartedAt.map { RFC3339.string(from: $0.date) },
      jobFinishedAt: record.jobFinishedAt.map { RFC3339.string(from: $0.date) },
      updatedAt: RFC3339.string(from: record.updatedAt.date),
      terminal: record.state.isTerminal)
  }
}
