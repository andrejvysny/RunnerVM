import Foundation
import RunnerCore

/// What the orchestrator is allowed to know about GitHub (spec §50).
///
/// Raw endpoint paths, HTTP statuses and `Authorization` headers stop here: the scheduler, the
/// repositories and the VM manager only ever see these five calls and `GitHubErrorClass`.
public protocol GitHubActionsControlPlane: Sendable {
  /// One registration for one VM boot. The returned config is a secret (spec §36).
  func generateJITConfig(scope: GitHubScope, request: JITRunnerRequest) async throws -> JITRunnerConfig
  /// Idempotent: succeeds when GitHub has already forgotten the runner.
  func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws
  /// `nil` when GitHub holds no runner under that name. The name is the only handle restart
  /// recovery has on a registration whose `generate-jitconfig` reply was lost.
  func findRunner(scope: GitHubScope, name: String) async throws -> GitHubRunner?
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

  /// Re-filtered locally: `?name=` is GitHub's own filter, and nothing guarantees it stays an
  /// exact match rather than a prefix one.
  public func findRunner(scope: GitHubScope, name: String) async throws -> GitHubRunner? {
    try await runners.listRunners(scope: scope, name: name).first { $0.name == name }
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
