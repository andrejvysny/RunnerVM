import Foundation
import RunnerCore
import Testing

@testable import GitHubControl

/// Looking a runner up by the name the JIT request carried. Restart recovery has nothing else to
/// go on when a `generate-jitconfig` reply was lost, so this is the only handle on a registration
/// whose id never reached the session row.
struct RunnerLookupTests {
  private static let page = "{\"total_count\":1,\"runners\":[\(Fixture.runnerJSON)]}"

  @Test func listingRunnersByNameNarrowsTheQueryServerSide() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.get, scope.runnersPath, .json(Self.page))

      let runners = try await harness.api.listRunners(scope: scope, name: "runnervm-abc")

      #expect(runners.count == 1)
      let recorded = try #require(harness.server.requests(.get, scope.runnersPath).first)
      #expect(recorded.query["name"] == "runnervm-abc")
    }
  }

  @Test func listingRunnersWithoutANameSendsNoFilter() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      harness.server.stub(.get, scope.runnersPath, .json(Self.page))

      _ = try await harness.api.listRunners(scope: scope)

      let recorded = try #require(harness.server.requests(.get, scope.runnersPath).first)
      #expect(recorded.query["name"] == nil)
    }
  }

  @Test func findRunnerDecodesTheMatchingRegistration() async throws {
    try await withHarness { harness in
      let scope = Fixture.repositoryScope
      let plane = RESTControlPlane(runners: harness.api)
      harness.server.stub(.get, scope.runnersPath, .json(Self.page))

      let found = try await plane.findRunner(scope: scope, name: "runnervm-abc")

      #expect(found?.id == 42)
      #expect(found?.name == "runnervm-abc")
      // GitHub owns the `?name=` filter; a near miss must not be taken for the runner we asked for.
      try #expect(await plane.findRunner(scope: scope, name: "runnervm-abcd") == nil)
    }
  }

  @Test func findRunnerReportsAnAbsentRegistration() async throws {
    try await withHarness { harness in
      let scope = Fixture.organizationScope
      let plane = RESTControlPlane(runners: harness.api)
      harness.server.stub(
        .get, scope.runnersPath, .json("{\"total_count\":0,\"runners\":[]}"))

      try #expect(await plane.findRunner(scope: scope, name: "runnervm-abc") == nil)
    }
  }

  @Test func theFakeScaleSetPlaneAnswersALookupByName() async throws {
    let plane = FakeScaleSetControlPlane()
    let scope = Fixture.organizationScope

    let config = try await plane.generateJITConfig(
      scope: scope, scaleSetID: 7, runnerName: "runnervm-abc", workFolder: "_work")

    let found = try #require(try await plane.runner(scope: scope, name: "runnervm-abc"))
    #expect(found.id == config.runnerID)
    try #expect(await plane.runner(scope: scope, name: "ghost") == nil)

    // A registration the daemon never learned the id of, then dropped by recovery.
    plane.seedRunner(id: 99, name: "runnervm-orphan")
    try #expect(await plane.runner(scope: scope, name: "runnervm-orphan")?.id == 99)
    try await plane.ensureRunnerRemoved(scope: scope, runnerID: 99)
    try #expect(await plane.runner(scope: scope, name: "runnervm-orphan") == nil)
  }
}
