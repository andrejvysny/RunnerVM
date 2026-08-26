import DaemonAPI
import Foundation
import GitHubControl
import ImageStore
import Metrics
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Spec §53: the daemon grades every local image's baked-in `actions/runner` against the newest
/// published release, and `imageUpdates.denyTooOldRunner` turns the worst grade into a refusal.
@Suite struct RunnerVersionTests {
  static let now = Date(timeIntervalSince1970: 1_756_000_000)
  static let releasePath = GitHubRunnersAPI.latestReleasePath

  // MARK: - Monitor

  @Test func refreshReadsTheLatestReleaseFromGitHub() async throws {
    try await withHarness(now: { Self.now }) { harness in
      let published = Self.now.addingTimeInterval(-3 * 86_400)
      harness.github.stubLatestRunnerRelease(tag: "v2.336.0", publishedAt: published)

      let release = await harness.runnerVersions.refresh()

      #expect(release?.version == "2.336.0")
      #expect(release?.publishedAt == published)
      #expect(await harness.runnerVersions.unavailable() == nil)
      #expect(await harness.runnerVersions.releaseAgeSeconds() == 3 * 86_400)
    }
  }

  /// A GitHub that stops answering must not turn every image `unknown`: the last verdict stands
  /// until a newer one replaces it.
  @Test func aFailedRefreshKeepsTheLastKnownRelease() async throws {
    try await withHarness(now: { Self.now }) { harness in
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-86_400))
      await harness.runnerVersions.refresh()

      harness.github.stub(.get, Self.releasePath, .error(500))
      await harness.runnerVersions.refresh()

      #expect(await harness.runnerVersions.latest()?.version == "2.336.0")
      #expect(await harness.runnerVersions.health(forVersion: "2.336.0") == .healthy)
    }
  }

  @Test func nothingIsGradedBeforeTheFirstSuccessfulLookup() async throws {
    try await withHarness(now: { Self.now }) { harness in
      #expect(await harness.runnerVersions.latest() == nil)
      #expect(await harness.runnerVersions.health(forVersion: "2.320.0") == .unknown)
      #expect(await harness.runnerVersions.unavailable() == .notFetchedYet)
      #expect(await harness.runnerVersions.releaseAgeSeconds() == nil)

      harness.github.stub(.get, Self.releasePath, .error(500))
      await harness.runnerVersions.refresh()

      #expect(await harness.runnerVersions.latest() == nil)
      guard case .lastAttemptFailed = await harness.runnerVersions.unavailable() else {
        Issue.record("expected the failure reason to be reported")
        return
      }
    }
  }

  /// The maintenance loop calls this every five minutes; the lookup itself is six-hourly.
  @Test func refreshIfDueOnlyQueriesOncePerInterval() async throws {
    try await withHarness { harness in
      harness.github.stubLatestRunnerRelease(tag: "v2.336.0", publishedAt: Date())

      await harness.runnerVersions.refreshIfDue()
      await harness.runnerVersions.refreshIfDue()
      await harness.runnerVersions.refreshIfDue()

      #expect(harness.github.requests(.get, Self.releasePath).count == 1)
    }
  }

  @Test func metadataIsGradedThroughTheSamePolicy() async throws {
    try await withHarness(now: { Self.now }) { harness in
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-90 * 86_400))
      await harness.runnerVersions.refresh()

      let metadata = ImageMetadata(
        os: .linux, virtualDiskSizeBytes: 1, runnerVersion: "2.300.0",
        createdAt: Self.now, boot: ImageMetadata.Boot(type: .efi))
      #expect(await harness.runnerVersions.health(for: metadata) == .tooOld)
    }
  }

  // MARK: - Surface

  @Test func imageListReportsTheRunnerVersionAndItsHealth() async throws {
    try await withHarness(now: { Self.now }) { harness in
      try await harness.importLinuxImage(runnerVersion: "2.320.0")
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-5 * 86_400))
      await harness.runnerVersions.refresh()

      let listed = try await harness.service().imageList().images
      let image = try #require(listed.first { $0.name == M2Harness.linuxImageName })
      #expect(image.runnerVersion == "2.320.0")
      #expect(image.runnerVersionHealth == .stale)

      let inspected = try await harness.service().imageGet(
        ImageGetRequest(ref: M2Harness.linuxImageName))
      #expect(inspected.runnerVersionHealth == .stale)
    }
  }

  @Test func statusCountsStaleAndTooOldImages() async throws {
    try await withHarness(now: { Self.now }) { harness in
      try await harness.importLinuxImage(runnerVersion: "2.300.0")
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-90 * 86_400))
      await harness.runnerVersions.refresh()

      let status = try await harness.service().status()
      #expect(status.images.runnerTooOld == 1)
      #expect(status.images.runnerStale == 0)
    }
  }

  @Test func maintenancePublishesTheFreshnessGauges() async throws {
    try await withHarness(now: { Self.now }) { harness in
      let image = try await harness.importLinuxImage(runnerVersion: "2.300.0")
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-90 * 86_400))
      await harness.runnerVersions.refresh()

      let service = harness.service()
      await service.refreshRunnerVersionMetrics()

      let snapshot = await harness.metrics.snapshot()
      let health = try #require(
        snapshot.families.first { $0.name == RunnerVMMetrics.imageRunnerVersionHealth })
      let sample = try #require(health.samples.first)
      #expect(sample.value == 1)
      #expect(sample.labels.contains(MetricLabel(name: "health", value: "tooOld")))
      #expect(
        sample.labels.contains(
          MetricLabel(name: "digest", value: image.record.digest.rawValue)))
      #expect(
        snapshot.families.contains { $0.name == RunnerVMMetrics.runnerLatestReleaseAgeSeconds })
    }
  }

  // MARK: - Admission (imageUpdates.denyTooOldRunner)

  @Test func aTooOldImageIsRefusedWhenDenyTooOldRunnerIsOn() async throws {
    var configuration = M2Harness.configuration()
    configuration.imageUpdates = ImageUpdatesConfig(denyTooOldRunner: true)
    try await withHarness(configuration: configuration, now: { Self.now }) { harness in
      try await harness.importLinuxImage(runnerVersion: "2.300.0")
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-90 * 86_400))
      await harness.runnerVersions.refresh()

      do {
        _ = try await harness.instances.create(profileName: "linux")
        Issue.record("create should have been refused")
      } catch let error as any RunnerError {
        #expect(error.code == "IMAGE_RUNNER_TOO_OLD")
      }

      // Refused before anything was materialized, and the planning pin was released.
      #expect(try await harness.instanceRows.list(profile: nil, states: nil).isEmpty)
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
    }
  }

  @Test func theSameImageIsAdmittedWhenDenyTooOldRunnerIsOff() async throws {
    try await withHarness(now: { Self.now }) { harness in
      try await harness.importLinuxImage(runnerVersion: "2.300.0")
      harness.github.stubLatestRunnerRelease(
        tag: "v2.336.0", publishedAt: Self.now.addingTimeInterval(-90 * 86_400))
      await harness.runnerVersions.refresh()

      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .waitingForAgent)
    }
  }

  /// Nothing was ever fetched, so the image grades `unknown` — which must never block, whatever
  /// the switch says.
  @Test func anUngradedImageIsAdmittedEvenWithDenyTooOldRunnerOn() async throws {
    var configuration = M2Harness.configuration()
    configuration.imageUpdates = ImageUpdatesConfig(denyTooOldRunner: true)
    try await withHarness(configuration: configuration, now: { Self.now }) { harness in
      try await harness.importLinuxImage(runnerVersion: "2.300.0")

      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .waitingForAgent)
    }
  }
}

extension M2Harness {
  /// Imports the linux image with a sealed `metadata.json`, so the stored image actually carries a
  /// `runnerVersion` for the freshness policy to grade. `importLocal` synthesises metadata
  /// otherwise, and a synthesised image is always `unknown`.
  @discardableResult
  func importLinuxImage(runnerVersion: String) async throws -> ManagedImage {
    let disk = try sparseFile(named: "linux-\(runnerVersion).img", bytes: 32 << 20)
    let metadata = ImageMetadata(
      os: .linux, architecture: "arm64", virtualDiskSizeBytes: 32 << 20,
      runnerVersion: runnerVersion, createdAt: M2Harness.imageClock,
      boot: ImageMetadata.Boot(type: .efi))
    let path = tree.root.appending(path: "sealed-\(runnerVersion).json")
    try JSONEncoder.imageMetadata().encode(metadata).write(to: path)
    return try await images.importLocal(
      disk: disk, nvram: nil, os: .linux, name: M2Harness.linuxImageName, metadataPath: path)
  }
}
