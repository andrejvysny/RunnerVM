import ConfigLoader
import DaemonAPI
import Foundation
import GitHubControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// `auth.*`, `github.test` and the scope reconciler (spec §12, §134, §135, §148). The credential
/// lives in the harness's temp state directory, so nothing here touches the login keychain or the
/// process environment.
@Suite struct GitHubAuthTests {
  @Test func authStatusIsUnconfiguredWithoutAToken() async throws {
    try await withHarness(githubToken: nil) { harness in
      let status = try await harness.service().authStatus()

      #expect(status.state == "unconfigured")
      #expect(status.provider == "pat")
      #expect(status.source == "file")
      #expect(status.location.hasSuffix("state/github-token"))
      #expect(status.hint == "run `runnerctl auth login --token-stdin`")
      #expect(status.login == nil)
    }
  }

  @Test func loginStoresAnOwnerOnlyTokenFileAndProbesTheLogin() async throws {
    try await withHarness(githubToken: nil) { harness in
      harness.stubGitHub(login: "octocat")
      let service = harness.service()

      let response = try await service.authLogin(
        AuthLoginRequest(token: "ghp_written_by_the_cli\n"))

      #expect(response.status.state == "healthy")
      #expect(response.status.login == "octocat")
      let path = harness.paths.stateDir.appending(path: "github-token")
        .path(percentEncoded: false)
      let mode = try #require(
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
          as? NSNumber)?.uint16Value)
      #expect(mode & 0o777 == 0o600)
      // The trailing newline a `--token-stdin` pipe always brings is trimmed on the way in.
      #expect(try String(contentsOfFile: path, encoding: .utf8) == "ghp_written_by_the_cli")
      // The token itself never appears in the response.
      #expect(!"\(response)".contains("ghp_written_by_the_cli"))
    }
  }

  @Test func logoutRemovesTheTokenAndIsIdempotent() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      let service = harness.service()

      let first = try await service.authLogout()
      let second = try await service.authLogout()

      #expect(first.removed)
      #expect(!second.removed)
      #expect(try await service.authStatus().state == "unconfigured")
    }
  }

  @Test func githubTestReportsTheCredentialAndEveryScope() async throws {
    try await withHarness { harness in
      harness.stubGitHub(login: "octocat", runners: "[]")

      let response = try await harness.service().githubTest()

      #expect(response.auth.state == "healthy")
      #expect(response.auth.login == "octocat")
      let scope = try #require(response.scopes.first)
      #expect(scope.name == "test")
      #expect(scope.slug == "acme/app")
      #expect(scope.status == "healthy")
      #expect(scope.schedulable)
      #expect(scope.runnerGroupId == 1)
      #expect(scope.visibility == "private")
      #expect(scope.runnerCount == 0)
      #expect(scope.problems.isEmpty)
    }
  }

  @Test func statusReportsTheCachedAuthStateAndHealthyScopeCount() async throws {
    try await withHarness { harness in
      harness.stubGitHub(login: "octocat")
      let service = harness.service()
      _ = try await service.githubTest()

      let status = try await service.status()

      #expect(status.github.authState == "healthy")
      #expect(status.github.authLogin == "octocat")
      #expect(status.github.scopeCount == 1)
      #expect(status.github.scopesHealthy == 1)
      #expect(!status.github.placeholder)
    }
  }

  @Test func anInvalidTokenIsReportedWithoutStoppingTheDaemon() async throws {
    try await withHarness { harness in
      harness.github.stub(.get, M2Harness.userPath, .error(401, message: "Bad credentials"))

      let status = try await harness.service().githubTest().auth

      #expect(status.state == "invalid")
      #expect(status.problem?.hasPrefix("GITHUB_AUTHENTICATION_FAILED") == true)
      #expect(status.hint == "run `runnerctl auth login --token-stdin`")
    }
  }
}

/// Runner-group resolution and the health hysteresis around an unreachable GitHub (spec §134).
@Suite struct ScopeHealthTests {
  private static let organizationYAML = """
    version: 1
    github:
      auth:
        provider: pat
        source: file
      scopes:
        - name: org
          type: organization
          owner: acme
          runnerGroup: runnervm
    profiles:
      - name: ubuntu-24
        scope: org
        image: ghcr.io/acme/runners/ubuntu-24:stable
        resources:
          cpu: 4
          memory: 8GiB
          disk: 80GiB
    """

  private static func stubOrganization(_ harness: M2Harness) {
    harness.github.stub(.get, "/user", .json("{\"login\":\"octocat\"}"))
    harness.github.stub(
      .get, "/orgs/acme/actions/runners", .json("{\"total_count\":0,\"runners\":[]}"))
    harness.github.stub(
      .get, "/orgs/acme/actions/runner-groups",
      .json("""
        {"total_count":2,"runner_groups":[{"id":1,"name":"Default"},{"id":7,"name":"runnervm"}]}
        """))
  }

  @Test func configApplyResolvesTheOrganizationRunnerGroup() async throws {
    try await withHarness { harness in
      Self.stubOrganization(harness)
      let service = harness.service(parseConfig: { try ConfigLoader.load(yaml: $0) })

      _ = try await service.configApply(ConfigApplyRequest(yaml: Self.organizationYAML))

      let record = try #require(
        try await GRDBScopeRepository(db: harness.database).get(name: "org"))
      #expect(record.runnerGroupName == "runnervm")
      #expect(record.runnerGroupId == 7)
      #expect(record.health == "healthy")
      // The repository scope from the harness document is gone from the document, so it is
      // disabled and no longer probed.
      #expect(try await GRDBScopeRepository(db: harness.database).get(name: "test")?.enabled == false)
    }
  }

  @Test func aMissingRunnerGroupTurnsTheScopeUnhealthy() async throws {
    try await withHarness { harness in
      Self.stubOrganization(harness)
      harness.github.stub(
        .get, "/orgs/acme/actions/runner-groups",
        .json("{\"total_count\":1,\"runner_groups\":[{\"id\":1,\"name\":\"Default\"}]}"))
      let service = harness.service(parseConfig: { try ConfigLoader.load(yaml: $0) })

      _ = try await service.configApply(ConfigApplyRequest(yaml: Self.organizationYAML))

      let record = try #require(
        try await GRDBScopeRepository(db: harness.database).get(name: "org"))
      #expect(record.health == "unhealthy")
    }
  }

  /// A dropped socket says nothing about the scope's permissions, so the last verdict stands
  /// until it is too stale to believe.
  @Test func anUnreachableGitHubKeepsTheLastHealthThenGoesUnknown() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      _ = await harness.scopeHealth.refresh()
      #expect(try await GRDBScopeRepository(db: harness.database).get(name: "test")?.health == "healthy")

      harness.github.stub(.get, M2Harness.runnersPath, .failure(.networkConnectionLost))
      harness.github.stub(.get, M2Harness.repositoryPath, .failure(.networkConnectionLost))

      for pass in 1 ... ScopeHealthMonitor.unreachableThreshold {
        let scopes = await harness.scopeHealth.refresh()
        let persisted = try await GRDBScopeRepository(db: harness.database).get(name: "test")
        #expect(scopes.first?.status == "degraded")
        #expect(
          persisted?.health
            == (pass < ScopeHealthMonitor.unreachableThreshold ? "healthy" : "unknown"))
      }
    }
  }
}
