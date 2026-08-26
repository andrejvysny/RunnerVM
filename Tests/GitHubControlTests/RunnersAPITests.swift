import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

struct GitHubRunnersAPITests {
  private static let jitBody = """
  {"runner":\(Fixture.runnerJSON),"encoded_jit_config":"eyJydW5uZXIiOiJzZWNyZXQifQ=="}
  """

  // MARK: - JIT configuration (spec §36)

  @Test func generatesJITConfigForARepository() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.post, scope.jitConfigPath, .json(Self.jitBody))

      let config = try await harness.api.generateJITConfig(
        scope: scope,
        request: JITRunnerRequest(
          name: "runnervm-abc", labels: ["self-hosted", "ubuntu-24"], workFolder: "_work"
        )
      )

      #expect(config.runnerID == 42)
      #expect(config.runnerName == "runnervm-abc")
      #expect(config.encodedJITConfig == "eyJydW5uZXIiOiJzZWNyZXQifQ==")

      let recorded = try #require(harness.server.requests(.post, scope.jitConfigPath).first)
      #expect(recorded.path == "/repos/acme/project-a/actions/runners/generate-jitconfig")
      #expect(recorded.bodyValue("name") as? String == "runnervm-abc")
      #expect(recorded.bodyValue("labels") as? [String] == ["self-hosted", "ubuntu-24"])
      #expect(recorded.bodyValue("work_folder") as? String == "_work")
      // A repository has one group; GitHub still requires the id.
      #expect(recorded.bodyValue("runner_group_id") as? Int == 1)
      #expect(recorded.header("Content-Type") == "application/json")
    }
  }

  @Test func generatesJITConfigForAnOrganizationWithItsRunnerGroup() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      harness.server.stub(.post, scope.jitConfigPath, .json(Self.jitBody))

      _ = try await harness.api.generateJITConfig(
        scope: scope, request: JITRunnerRequest(name: "runnervm-abc", labels: ["self-hosted"])
      )

      let recorded = try #require(harness.server.requests(.post, scope.jitConfigPath).first)
      #expect(recorded.path == "/orgs/acme/actions/runners/generate-jitconfig")
      #expect(recorded.bodyValue("runner_group_id") as? Int == 7)
      #expect(recorded.bodyValue("work_folder") == nil)
    }
  }

  @Test func jitRequestOverridesTheScopeRunnerGroup() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      harness.server.stub(.post, scope.jitConfigPath, .json(Self.jitBody))
      _ = try await harness.api.generateJITConfig(
        scope: scope,
        request: JITRunnerRequest(name: "n", labels: ["self-hosted"], runnerGroupID: 99)
      )
      let recorded = try #require(harness.server.requests(.post, scope.jitConfigPath).first)
      #expect(recorded.bodyValue("runner_group_id") as? Int == 99)
    }
  }

  @Test func emptyJITConfigIsRejected() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(
        .post, scope.jitConfigPath,
        .json("{\"runner\":\(Fixture.runnerJSON),\"encoded_jit_config\":\"\"}")
      )
      let error = await captureError {
        _ = try await harness.api.generateJITConfig(
          scope: scope, request: JITRunnerRequest(name: "n", labels: [])
        )
      }
      let captured = try #require(error) as? GitHubControlError
      #expect(captured?.code == "GITHUB_JIT_GENERATION_FAILED")
    }
  }

  // MARK: - Runner lifecycle

  @Test func listsRunnersAcrossTheScope() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(
        .get, scope.runnersPath,
        .json("{\"total_count\":1,\"runners\":[\(Fixture.runnerJSON)]}")
      )
      let runners = try await harness.api.listRunners(scope: scope)
      #expect(runners.count == 1)
      #expect(runners[0].labelNames == ["self-hosted", "ubuntu-24"])
      #expect(runners[0].isOnline)
      #expect(runners[0].state == .online(busy: false))
    }
  }

  @Test func removingAnAbsentRunnerSucceeds() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.delete, scope.runnerPath(id: 42), .error(404, message: "Not Found"))
      try await harness.api.removeRunner(scope: scope, id: 42)
      #expect(harness.server.requests(.delete, scope.runnerPath(id: 42)).count == 1)
    }
  }

  @Test func removingARunnerAcceptsNoContent() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      harness.server.stub(.delete, scope.runnerPath(id: 42), .empty(204))
      try await harness.api.removeRunner(scope: scope, id: 42)
      let recorded = try #require(harness.server.recorded.first)
      #expect(recorded.path == "/orgs/acme/actions/runners/42")
    }
  }

  @Test func unknownRunnerHasNoState() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.get, scope.runnerPath(id: 7), .error(404, message: "Not Found"))
      try #expect(try await harness.api.getRunner(scope: scope, id: 7) == nil)
      try #expect(try await harness.api.runnerState(scope: scope, id: 7) == .absent)
    }
  }

  // MARK: - Runner groups (spec §134)

  @Test func resolvesRunnerGroupIDCaseInsensitively() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, GitHubScope.runnerGroupsPath(org: "acme"),
        .json(
          "{\"total_count\":2,\"runner_groups\":[{\"id\":1,\"name\":\"Default\"},"
            + "{\"id\":5,\"name\":\"macOS Builders\",\"visibility\":\"selected\"}]}"
        )
      )
      try #expect(try await harness.api.resolveRunnerGroupID(org: "acme", name: "macos builders") == 5)
    }
  }

  @Test func missingRunnerGroupIsNotFound() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, GitHubScope.runnerGroupsPath(org: "acme"),
        .json("{\"total_count\":1,\"runner_groups\":[{\"id\":1,\"name\":\"Default\"}]}")
      )
      let error = await captureError {
        _ = try await harness.api.resolveRunnerGroupID(org: "acme", name: "gpu")
      }
      try #expect(try errorClass(of: #require(error)) == .notFound)
    }
  }

  // MARK: - Repository visibility (spec §77) and runner version (spec §53)

  @Test func readsRepositoryVisibility() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/repos/acme/project-a", .json("{\"private\":false,\"visibility\":\"public\"}")
      )
      let visibility = try await harness.api.repositoryVisibility(
        owner: "acme", repository: "project-a"
      )
      #expect(visibility.isPublic)
      #expect(!visibility.isPrivate)
    }
  }

  @Test func publicRepositoryIsRejectedUnlessAllowed() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/repos/acme/project-a", .json("{\"private\":false,\"visibility\":\"public\"}")
      )
      let error = await captureError {
        try await harness.api.assertScopeAllowed(
          scope: Fixture.repositoryScope, allowPublicRepositories: false
        )
      }
      try #expect(try (#require(error) as? GitHubControlError)?
        .code == "GITHUB_PUBLIC_REPOSITORY_NOT_ALLOWED")

      // Opted in: no request is even needed.
      try await harness.api.assertScopeAllowed(
        scope: Fixture.repositoryScope, allowPublicRepositories: true
      )
      #expect(harness.server.requests(.get, "/repos/acme/project-a").count == 1)
    }
  }

  @Test func stripsTheVFromTheLatestRunnerRelease() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, GitHubRunnersAPI.latestReleasePath,
        .json("{\"tag_name\":\"v2.319.1\",\"published_at\":\"2024-11-04T18:00:00Z\"}")
      )
      try #expect(try await harness.api.latestRunnerVersion() == "2.319.1")
    }
  }

  /// The publication date is what the 30-day staleness window is measured from (spec §53), so it
  /// is decoded, not skipped.
  @Test func readsThePublicationDateOfTheLatestRunnerRelease() async throws {
    try await withHarness { harness in
      let published = Date(timeIntervalSince1970: 1_730_745_600)
      harness.server.stubLatestRunnerRelease(tag: "v2.336.0", publishedAt: published)
      let release = try await harness.api.latestRunnerRelease()
      #expect(release.version == "2.336.0")
      #expect(release.publishedAt == published)
    }
  }

  @Test func acceptsAFractionalSecondsPublicationTimestamp() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, GitHubRunnersAPI.latestReleasePath,
        .json("{\"tag_name\":\"2.336.0\",\"published_at\":\"2024-11-04T18:00:00.123Z\"}")
      )
      try #expect(try await harness.api.latestRunnerRelease().version == "2.336.0")
    }
  }

  /// Without a usable timestamp the release cannot be graded at all, so this is an invalid
  /// response rather than a release with an invented date.
  @Test func aReleaseWithoutAPublicationDateIsRejected() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, GitHubRunnersAPI.latestReleasePath, .json("{\"tag_name\":\"v2.336.0\"}")
      )
      await #expect(throws: GitHubControlError.self) {
        try await harness.api.latestRunnerRelease()
      }
    }
  }

  // MARK: - Scope health (spec §134, §135, §148)

  @Test func healthyScopeReportsNoProblems() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.get, scope.runnersPath, .json("{\"total_count\":0,\"runners\":[]}"))
      harness.server.stub(
        .get, "/repos/acme/project-a", .json("{\"private\":true,\"visibility\":\"private\"}")
      )
      let health = await harness.api.checkPermissions(scope: scope)
      #expect(health.ok)
      #expect(health.status == .healthy)
      #expect(health.runnerCount == 0)
      #expect(health.visibility?.isPrivate == true)
    }
  }

  @Test func brokenCredentialMakesTheScopeUnhealthy() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      harness.server.stub(.get, scope.runnersPath, .error(401, message: "Bad credentials"))
      harness.server.stub(
        .get, GitHubScope.runnerGroupsPath(org: "acme"),
        .json("{\"total_count\":1,\"runner_groups\":[{\"id\":5,\"name\":\"gpu\"}]}")
      )
      let health = await harness.api.checkPermissions(scope: scope, runnerGroup: "gpu")
      #expect(!health.ok)
      #expect(health.status == .unhealthy)
      #expect(health.problems.map(\.errorClass) == [.authentication])
      // The group still resolves, so the id is reported alongside the problem.
      #expect(health.runnerGroupID == 5)
    }
  }

  @Test func rateLimitedScopeIsDegradedNotUnhealthy() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      harness.server.stub(.get, scope.runnersPath, .error(429, headers: ["Retry-After": "1"]))
      let health = await harness.api.checkPermissions(scope: scope)
      #expect(health.status == .degraded)
      #expect(health.runnerGroupID == 7)
    }
  }

  // MARK: - Control plane surface (spec §50)

  @Test func controlPlaneDelegatesToTheRESTAPI() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      let plane = RESTControlPlane(runners: harness.api)
      harness.server.stub(.post, scope.jitConfigPath, .json(Self.jitBody))
      harness.server.stub(.delete, scope.runnerPath(id: 42), .empty(204))
      harness.server.stub(.get, scope.runnerPath(id: 42), .json(Fixture.runnerJSON))

      let config = try await plane.generateJITConfig(
        scope: scope, request: JITRunnerRequest(name: "runnervm-abc", labels: [])
      )
      #expect(config.runnerID == 42)
      try #expect(try await plane.runnerState(scope: scope, runnerID: 42) == .online(busy: false))
      try await plane.ensureRunnerRemoved(scope: scope, runnerID: 42)
    }
  }

  // MARK: - Scope paths (spec §11)

  @Test func scopeBuildsPathsFromConfiguration() throws {
    let organization = try GitHubScope(
      config: GitHubScopeConfig(name: "engineering", kind: .organization, owner: "acme"),
      runnerGroupID: 3
    )
    #expect(organization.runnersPath == "/orgs/acme/actions/runners")
    #expect(organization.runnerGroupID == 3)

    let repository = try GitHubScope(
      config: GitHubScopeConfig(
        name: "project-a", kind: .repository, owner: "acme", repository: "project a"
      )
    )
    // Configuration text is escaped rather than trusted to be path-safe.
    #expect(repository.runnersPath == "/repos/acme/project%20a/actions/runners")
    #expect(repository.runnerGroupID == GitHubScope.defaultRunnerGroupID)

    #expect(throws: GitHubControlError.self) {
      try GitHubScope(
        config: GitHubScopeConfig(name: "broken", kind: .repository, owner: "acme")
      )
    }
  }
}
