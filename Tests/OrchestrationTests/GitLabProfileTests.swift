import Foundation
import GitHubControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// GitLab profiles only supply VMs on gitlab-runner's request, so every GitHub path must skip them.
@Suite struct GitLabProfileTests {
  private static func configWithGitLabProfile() -> RunnerConfiguration {
    var config = M2Harness.configuration()
    config.profiles.append(
      RunnerProfileConfig(
        name: "glab", scope: nil, provider: .gitlab, image: "ghcr.io/acme/glab:stable",
        guestOS: .linux))
    return config
  }

  @Test func aGitLabProfileNeverRegistersAScaleSetOrOpensASession() async throws {
    try await withHarness(configuration: Self.configWithGitLabProfile()) { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      try await provider.start()
      await provider.refresh()

      #expect(!harness.scaleSetPlane.ensureCalls().map(\.name).contains("runnervm-glab"))
      let gitlab = try await harness.profileID("glab")
      #expect(try await harness.scaleSets.get(profileId: gitlab) == nil)
      #expect(await provider.report().allSatisfy { $0.profileId != gitlab })
      await provider.stop()
    }
  }

  @Test func aTickNeverStartsInstancesForAGitLabProfile() async throws {
    try await withHarness(configuration: Self.configWithGitLabProfile()) { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      try await provider.start()
      let orchestrator = await harness.orchestrator(
        demand: provider, configuration: Self.configWithGitLabProfile())
      await orchestrator.tick()

      #expect(try await harness.instanceCount(profile: "glab") == 0)
      #expect(await orchestrator.demandReport().allSatisfy { $0.scaleSetName != "runnervm-glab" })
      await provider.stop()
    }
  }
}
