import DaemonAPI
import Foundation
import ImageStore
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Profile `image:` values that name a registry, and the `registry.*` credential surface.
@Suite struct RegistryCredentialTests {
  /// Spec §21: a profile may name a tag, but the instance record must carry the digest the tag
  /// resolved to, and the image has to be on this host before the VM starts.
  @Test func createPullsAProfileImageThatNamesARegistry() async throws {
    let fake = FakeRegistry()
    let configuration = M2Harness.configuration(
      linuxImage: "\(fake.host)/acme/runners/ubuntu-24:stable")
    try await withHarness(configuration: configuration, registry: fake) { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))

      let record = try await harness.instances.create(profileName: "linux")

      #expect(record.state == .waitingForAgent)
      let image = try #require(try await harness.imageRows.get(digest: record.imageDigest))
      #expect(image.state == .ready)
      #expect(image.canonicalReference
        == published.reference.canonical(withDigest: published.manifestDigest).description)
      #expect(await harness.metrics.histogram(
        name: RunnerVMMetrics.imagePullSeconds,
        labels: [RunnerVMMetrics.profileLabel: "linux"]) != nil)
    }
  }

  /// The second create must not talk to the registry again inside the tag TTL.
  @Test func aSecondCreateReusesTheResolvedTagWithoutAnotherRoundTrip() async throws {
    let fake = FakeRegistry()
    let configuration = M2Harness.configuration(
      linuxImage: "\(fake.host)/acme/runners/ubuntu-24:stable")
    try await withHarness(configuration: configuration, registry: fake) { harness in
      _ = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      _ = try await harness.instances.create(profileName: "linux")
      harness.registry.resetRecording()

      _ = try await harness.instances.create(profileName: "linux")

      #expect(harness.registry.recorded.isEmpty)
    }
  }

  @Test func loginStoresACredentialThatStatusThenReports() async throws {
    let fake = FakeRegistry()
    let configuration = M2Harness.configuration(linuxImage: "\(fake.host)/acme/runners/ubuntu:1")
    try await withHarness(configuration: configuration, registry: fake) { harness in
      let service = harness.service()

      let before = try await service.registryStatus()
      #expect(before.registries.map(\.registry) == [fake.host])
      #expect(before.registries.first?.provider == nil)

      let login = try await service.registryLogin(
        RegistryLoginRequest(registry: fake.host, username: "octocat", password: "ghp_secret"))
      #expect(login.username == "octocat")
      #expect(login.location == "keychain \(fake.host)")

      let after = try await service.registryStatus()
      #expect(after.registries.first?.provider == "keychain")
      #expect(after.registries.first?.username == "octocat")
      #expect(after.registries.first?.profiles == ["linux"])
      // The password never leaves the keychain through this surface.
      #expect(!"\(after)".contains("ghp_secret"))

      let logout = try await service.registryLogout(RegistryLogoutRequest(registry: fake.host))
      #expect(logout.removed)
      #expect(try await service.registryLogout(RegistryLogoutRequest(registry: fake.host)).removed
        == false)
      #expect(try await service.registryStatus().registries.first?.provider == nil)
    }
  }

  /// A full reference is the most common way this argument gets pasted in wrong; the host is what
  /// the Keychain item is keyed by.
  @Test func loginAcceptsAFullReferenceAndStoresItUnderTheHost() async throws {
    try await withHarness { harness in
      let service = harness.service()
      let login = try await service.registryLogin(
        RegistryLoginRequest(
          registry: "ghcr.io/acme/runners:stable", username: "octocat", password: "ghp_secret"))

      #expect(login.registry == "ghcr.io")
      #expect(try harness.registryKeychain.internetPassword(server: "ghcr.io")?.username
        == "octocat")
    }
  }

  @Test func imagePullOverTheServiceReportsTheOperationAndTheResolvedDigest() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      let service = harness.service()

      let response = try await service.imagePull(
        ImagePullRequest(reference: published.reference.description))

      #expect(response.manifestDigest == published.manifestDigest.rawValue)
      #expect(response.alreadyPresent == false)
      let operationId = try #require(response.operationId)
      try await waitUntil("the pull operation to finish") {
        try await GRDBOperationRepository(db: harness.database).list(state: nil)
          .first { $0.id.rawValue == operationId }?.state == .succeeded
      }
      let listed = try await service.imageList()
      #expect(listed.images.first?.canonicalReference == response.reference)
      #expect(listed.images.first?.state == "ready")
      #expect(try await service.status().images.pulling == 0)
    }
  }
}
