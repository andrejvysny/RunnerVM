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

  public static let latestReleasePath = "/repos/actions/runner/releases/latest"
  public static let runnerReleasesPath = "/repos/actions/runner/releases"
  /// A server that keeps advertising a next page must not turn this into an unbounded fetch.
  private static let maxReleasePages = 20

  /// Latest published `actions/runner` release, for the image staleness check: the tag without its
  /// leading `v`, plus the publication date `RunnerVersionPolicy` measures its grace window from.
  /// Compared against `ImageMetadata.runnerVersion`.
  public func latestRunnerRelease() async throws -> LatestRunnerRelease {
    let release = try await client.send(
      GitHubRequest.get(Self.latestReleasePath), as: Wire.Release.self
    ).value
    let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    guard !version.isEmpty else {
      throw GitHubControlError.invalidResponse(reason: "actions/runner release has an empty tag")
    }
    guard let publishedAt = Self.parseTimestamp(release.publishedAt) else {
      throw GitHubControlError.invalidResponse(
        reason: "actions/runner release \(release.tagName) has no usable published_at")
    }
    return LatestRunnerRelease(version: version, publishedAt: publishedAt)
  }

  public func latestRunnerVersion() async throws -> String {
    try await latestRunnerRelease().version
  }

  /// Up to `limit` recent, published, non-draft, non-prerelease `actions/runner` releases, newest
  /// first — the window `RunnerVersionPolicy` grades an image against (spec §53). Unlike
  /// `latestRunnerRelease`, this needs more than the single newest release: the 30-day grace clock
  /// is measured from the *first* release an image missed, and that can only be found by looking
  /// at the releases between the image's version and the newest one.
  ///
  /// Paginates only until `limit` is collected — the endpoint can carry years of history and the
  /// policy never needs more than a bounded recent window.
  public func recentRunnerReleases(limit: Int = 60) async throws -> RunnerReleaseHistory {
    var collected: [RunnerRelease] = []
    var request: GitHubRequest? = GitHubRequest.get(
      Self.runnerReleasesPath, query: [URLQueryItem(name: "per_page", value: "100")])
    var pages = 0
    while let current = request, collected.count < limit, pages < Self.maxReleasePages {
      let response = try await client.send(current, as: [Wire.Release].self)
      collected.append(contentsOf: Self.usableReleases(response.value))
      request = response.nextPage.map(GitHubRequest.following)
      pages += 1
    }
    let releases = Array(collected.sorted { $0.publishedAt > $1.publishedAt }.prefix(limit))
    return RunnerReleaseHistory(releases: releases, latest: Self.highestVersion(of: releases))
  }

  /// Drops drafts, prereleases, and anything whose tag or `published_at` cannot be trusted, rather
  /// than failing the whole page over one bad entry.
  private static func usableReleases(_ page: [Wire.Release]) -> [RunnerRelease] {
    page.compactMap { release in
      guard release.draft != true, release.prerelease != true,
            let publishedAt = parseTimestamp(release.publishedAt)
      else { return nil }
      let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
      guard !version.isEmpty else { return nil }
      return RunnerRelease(version: version, publishedAt: publishedAt)
    }
  }

  /// Not `releases.first`: publication order is not guaranteed to track version order.
  private static func highestVersion(of releases: [RunnerRelease]) -> RunnerRelease? {
    releases
      .compactMap { release in SemanticVersion(release.version).map { (release, $0) } }
      .max { $0.1 < $1.1 }?
      .0
  }

  /// Built per call rather than held: `ISO8601DateFormatter` is a non-`Sendable` reference type and
  /// this runs once every few hours.
  private static func parseTimestamp(_ text: String?) -> Date? {
    guard let text, !text.isEmpty else { return nil }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
  }

  // MARK: - Credential health (spec §148)

  /// Login behind the credential. A GitHub App installation token has no user, so this is a PAT
  /// health check only — `checkPermissions` is the scope-level probe.
  public func whoAmI() async throws -> String {
    try await client.send(GitHubRequest.get("/user"), as: Wire.AuthenticatedUser.self).value.login
  }
}
