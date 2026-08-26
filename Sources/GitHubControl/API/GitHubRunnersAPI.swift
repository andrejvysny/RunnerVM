import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Every GitHub REST endpoint RunnerVM needs today, and the only place their paths exist.
/// Scale-set (Actions service) endpoints are M6 and do not belong here (spec §50, §51).
public struct GitHubRunnersAPI: Sendable {
  private let client: GitHubHTTPClient
  private let logger: Logger

  public init(client: GitHubHTTPClient, logger: Logger = Logger(component: .github)) {
    self.client = client
    self.logger = logger
  }

  // MARK: - Just-in-time runners (spec §36)

  /// `POST /{scope}/actions/runners/generate-jitconfig`.
  ///
  /// Deliberately **not** retried: a repeated POST that GitHub already processed leaves an orphan
  /// runner registration behind that nothing will ever claim.
  public func generateJITConfig(
    scope: GitHubScope, request: JITRunnerRequest
  ) async throws -> JITRunnerConfig {
    let body = Wire.JITConfigRequest(
      name: request.name,
      runnerGroupID: request.runnerGroupID ?? scope.runnerGroupID,
      labels: request.labels,
      workFolder: request.workFolder
    )
    let httpRequest = try GitHubRequest.post(scope.jitConfigPath, json: body)
    let response = try await client.send(httpRequest, as: Wire.JITConfigResponse.self)
    let config = JITRunnerConfig(
      runnerID: response.value.runner.id,
      runnerName: response.value.runner.name,
      encodedJITConfig: response.value.encodedJITConfig
    )
    guard !config.encodedJITConfig.isEmpty else {
      throw GitHubControlError.jitGenerationFailed(
        reason: "GitHub returned an empty JIT config for runner \(config.runnerName)"
      )
    }
    // The config itself is a secret and never reaches a log line (spec §36).
    logger.info(
      "generated JIT runner config",
      metadata: [
        "scope": .string(scope.description), "runner_id": .stringConvertible(config.runnerID),
        "runner_name": .string(config.runnerName),
      ]
    )
    return config
  }

  // MARK: - Runners

  public func listRunners(scope: GitHubScope) async throws -> [GitHubRunner] {
    try await client.paginate(
      GitHubRequest.get(scope.runnersPath), of: Wire.RunnersPage.self, items: { $0.runners }
    )
  }

  /// `nil` when GitHub does not know the runner — already removed, or never registered.
  public func getRunner(scope: GitHubScope, id: Int64) async throws -> GitHubRunner? {
    do {
      return try await client.send(
        GitHubRequest.get(scope.runnerPath(id: id)), as: GitHubRunner.self
      ).value
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      return nil
    }
  }

  /// Idempotent by design: cleanup runs on every instance teardown, and a runner GitHub already
  /// dropped (JIT runners self-delete after one job) must not fail the teardown.
  public func removeRunner(scope: GitHubScope, id: Int64) async throws {
    do {
      try await client.send(GitHubRequest.delete(scope.runnerPath(id: id)))
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      logger.debug(
        "runner already absent",
        metadata: ["scope": .string(scope.description), "runner_id": .stringConvertible(id)]
      )
    }
  }

  public func runnerState(scope: GitHubScope, id: Int64) async throws -> GitHubRunnerState {
    try await getRunner(scope: scope, id: id)?.state ?? .absent
  }

  // MARK: - Runner groups (spec §134)

  public func runnerGroups(org: String) async throws -> [RunnerGroup] {
    try await client.paginate(
      GitHubRequest.get(GitHubScope.runnerGroupsPath(org: org)), of: Wire.RunnerGroupsPage.self,
      items: { $0.runnerGroups }
    )
  }

  /// Resolved once at configuration-apply time and stored as `runner_group_id`; a group that
  /// later disappears turns the scope degraded rather than failing every JIT request.
  public func resolveRunnerGroupID(org: String, name: String) async throws -> Int64 {
    let groups = try await runnerGroups(org: org)
    guard
      let match = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    else {
      throw GitHubControlError.notFound(
        resource: "runner group '\(name)' in organization \(org)"
      )
    }
    return match.id
  }

  // MARK: - Repository visibility (spec §77)

  public func repositoryVisibility(
    owner: String, repository: String
  ) async throws -> RepositoryVisibility {
    try await client.send(
      GitHubRequest.get(GitHubScope.repositoryPath(owner: owner, repository: repository)),
      as: RepositoryVisibility.self
    ).value
  }

  /// Throws unless the scope is safe to run jobs for: public repositories need an explicit
  /// opt-in, because a fork's pull request would otherwise execute on the host's hardware.
  public func assertScopeAllowed(scope: GitHubScope, allowPublicRepositories: Bool) async throws {
    guard case let .repository(owner, repository) = scope, !allowPublicRepositories else { return }
    let visibility = try await repositoryVisibility(owner: owner, repository: repository)
    guard !visibility.isPublic else {
      throw GitHubControlError.publicRepositoryNotAllowed(scope: scope.slug)
    }
  }

  // MARK: - Runner software version (spec §53)

  /// Latest published `actions/runner` release, without the leading `v`, for the image staleness
  /// check. Compared against `ImageMetadata.runnerVersion`.
  public func latestRunnerVersion() async throws -> String {
    let release = try await client.send(
      GitHubRequest.get("/repos/actions/runner/releases/latest"), as: Wire.Release.self
    ).value
    let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    guard !version.isEmpty else {
      throw GitHubControlError.invalidResponse(reason: "actions/runner release has an empty tag")
    }
    return version
  }

  // MARK: - Credential health (spec §148)

  /// Login behind the credential. A GitHub App installation token has no user, so this is a PAT
  /// health check only — `checkPermissions` is the scope-level probe.
  public func whoAmI() async throws -> String {
    try await client.send(GitHubRequest.get("/user"), as: Wire.AuthenticatedUser.self).value.login
  }
}
