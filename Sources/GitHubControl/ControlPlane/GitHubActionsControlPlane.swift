import Foundation
import RunnerCore

/// What the orchestrator is allowed to know about GitHub (spec §50).
///
/// Raw endpoint paths, HTTP statuses and `Authorization` headers stop here: the scheduler, the
/// repositories and the VM manager only ever see these four calls and `GitHubErrorClass`.
public protocol GitHubActionsControlPlane: Sendable {
  /// One registration for one VM boot. The returned config is a secret (spec §36).
  func generateJITConfig(scope: GitHubScope, request: JITRunnerRequest) async throws -> JITRunnerConfig
  /// Idempotent: succeeds when GitHub has already forgotten the runner.
  func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws
  func runnerState(scope: GitHubScope, runnerID: Int64) async throws -> GitHubRunnerState
  func scopeHealth(scope: GitHubScope, runnerGroup: String?, allowPublicRepositories: Bool) async
    -> GitHubScopeHealth
}

/// REST implementation, sufficient for M5: runners are created on demand by the daemon and
/// registered with `generate-jitconfig`.
public struct RESTControlPlane: GitHubActionsControlPlane {
  private let runners: GitHubRunnersAPI

  public init(runners: GitHubRunnersAPI) {
    self.runners = runners
  }

  public init(client: GitHubHTTPClient) {
    self.init(runners: GitHubRunnersAPI(client: client))
  }

  public var api: GitHubRunnersAPI {
    runners
  }

  public func generateJITConfig(
    scope: GitHubScope, request: JITRunnerRequest
  ) async throws -> JITRunnerConfig {
    try await runners.generateJITConfig(scope: scope, request: request)
  }

  public func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws {
    try await runners.removeRunner(scope: scope, id: runnerID)
  }

  public func runnerState(scope: GitHubScope, runnerID: Int64) async throws -> GitHubRunnerState {
    try await runners.runnerState(scope: scope, id: runnerID)
  }

  public func scopeHealth(
    scope: GitHubScope, runnerGroup: String? = nil, allowPublicRepositories: Bool = false
  ) async -> GitHubScopeHealth {
    await runners.checkPermissions(
      scope: scope, runnerGroup: runnerGroup, allowPublicRepositories: allowPublicRepositories
    )
  }
}
