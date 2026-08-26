import DaemonAPI
import Foundation
import GitHubControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Resolves and persists per-scope GitHub health (spec §134, §135).
///
/// Runs at `config.apply` and on the daemon's slow maintenance loop. The persisted `health` is
/// the value the scheduler reads, so it deliberately lags: a rate limit or a dropped socket keeps
/// the last known verdict for a few passes rather than parking every profile on the host.
public actor ScopeHealthMonitor {
  /// Consecutive unreachable passes before the last known health stops being believable.
  public static let unreachableThreshold = 3

  private let scopes: any ScopeRepository
  private let gateway: GitHubGateway
  private let logger: Logger
  private var unreachablePasses: [String: Int] = [:]

  public init(
    scopes: any ScopeRepository, gateway: GitHubGateway,
    logger: Logger = Logger(component: .github)
  ) {
    self.scopes = scopes
    self.gateway = gateway
    self.logger = logger
  }

  /// One pass over every enabled scope. Never throws: a broken scope is state the scheduler
  /// reacts to, not an error that aborts the maintenance tick.
  @discardableResult
  public func refresh() async -> [ScopeHealthDTO] {
    guard let records = try? await scopes.list() else { return [] }
    let enabled = records.filter(\.enabled)
    guard let api = await gateway.runnersAPI() else {
      // No credential provider at all: report what is persisted, change nothing.
      return enabled.map { GitHubMapping.scopeHealth($0, probe: nil) }
    }
    let allowPublic = await gateway.allowPublicRepositories()
    var result: [ScopeHealthDTO] = []
    for record in enabled {
      result.append(await refresh(record, api: api, allowPublicRepositories: allowPublic))
    }
    return result
  }

  private func refresh(
    _ record: GitHubScopeRecord, api: GitHubRunnersAPI, allowPublicRepositories: Bool
  ) async -> ScopeHealthDTO {
    guard let scope = try? GitHubMapping.scope(record) else {
      let broken = await persist(record, health: "unhealthy", groupID: nil, isPublic: nil)
      return GitHubMapping.scopeHealth(broken, probe: nil)
    }
    let probe = await api.checkPermissions(
      scope: scope, runnerGroup: record.runnerGroupName,
      allowPublicRepositories: allowPublicRepositories)
    let health = resolve(probe, for: record)
    // A repository always has exactly one group — GitHub's default, id 1 — and still requires it
    // to be sent on the JIT request (spec §134).
    let groupID = record.kind == .repository
      ? GitHubScope.defaultRunnerGroupID
      : probe.runnerGroupID ?? record.runnerGroupId
    let updated = await persist(
      record, health: health, groupID: groupID, isPublic: probe.visibility?.isPublic)
    if updated.health != record.health {
      logger.notice(
        "scope health changed",
        metadata: [
          "scope": .string(record.name), "from": .string(record.health),
          "to": .string(updated.health),
          "problems": .array(probe.problems.map { .string($0.code) }),
        ])
    }
    return GitHubMapping.scopeHealth(updated, probe: probe)
  }

  /// `degraded` never lands in the column: it means "GitHub did not answer", which is a statement
  /// about the network, not about the scope. After `unreachableThreshold` such passes the last
  /// verdict is stale enough to be worth admitting to.
  private func resolve(_ probe: GitHubScopeHealth, for record: GitHubScopeRecord) -> String {
    switch probe.status {
    case .healthy, .unhealthy:
      unreachablePasses[record.name] = 0
      return probe.status.rawValue
    case .degraded, .unknown:
      let passes = (unreachablePasses[record.name] ?? 0) + 1
      unreachablePasses[record.name] = passes
      return passes >= Self.unreachableThreshold
        ? GitHubScopeHealth.Status.unknown.rawValue : record.health
    }
  }

  private func persist(
    _ record: GitHubScopeRecord, health: String, groupID: Int64?, isPublic: Bool?
  ) async -> GitHubScopeRecord {
    var updated = record
    updated.health = health
    if let groupID { updated.runnerGroupId = groupID }
    if let isPublic { updated.isPublicRepository = isPublic }
    guard updated != record else { return record }
    do {
      try await scopes.upsert(updated)
    } catch {
      logger.warning(
        "could not persist scope health",
        metadata: ["scope": .string(record.name), "error": .string(String(describing: error))])
      return record
    }
    return updated
  }
}
