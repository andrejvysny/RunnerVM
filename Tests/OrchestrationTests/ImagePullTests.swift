import Foundation
import ImageStore
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// M9: `ImageManager.pull` / `push` against `FakeRegistry`. Nothing here sleeps, and everything
/// runs inside `withHarness`, so no `/tmp/rvm-orch-*` tree survives the suite.
@Suite struct ImagePullTests {
  /// The local `ImageDigest` is computed from content alone (spec §21), so an image that went
  /// through a registry must land under exactly the digest a local import of the same bytes gives.
  @Test func pullImportsTheArtifactUnderTheLocalContentDigest() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"), withNVRAM: true)
      let expected = try await harness.mirrorImport(published)

      let record = try await harness.images.pull(reference: published.reference.description)

      #expect(record.digest == expected)
      #expect(record.state == .ready)
      #expect(record.canonicalReference?.contains("@sha256:") == true)
      #expect(record.pulledAt != nil)
      #expect(try await harness.imageStore.exists(record.digest))
      // The transient row keyed by the registry manifest digest is gone once the real one lands.
      let states = try await harness.imageRows.list(state: nil).map(\.state)
      #expect(states == [.ready])
    }
  }

  @Test func pullOfADigestAlreadyInTheStoreMovesNoBytes() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      let first = try await harness.images.pull(reference: published.reference.description)
      harness.registry.resetRecording()

      let second = try await harness.images.pull(reference: published.reference.description)

      #expect(second.digest == first.digest)
      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(try await harness.images.list().count == 1)
    }
  }

  /// Spec §137: five jobs needing the same uncached image must produce one download, not five.
  @Test func concurrentPullsOfTheSameDigestShareOneTransfer() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      harness.registry.resetRecording()

      async let first = harness.images.pull(reference: published.reference.description)
      async let second = harness.images.pull(reference: published.reference.description)
      async let third = harness.images.pull(reference: published.reference.description)
      let records = try await [first, second, third]

      #expect(Set(records.map(\.digest)).count == 1)
      #expect(published.chunkFetches(harness.registry) == published.chunkDigests.count)
      #expect(try await harness.images.list().count == 1)
    }
  }

  /// The disk chunks all verify before the NVRAM layer is fetched, so failing NVRAM leaves a
  /// staging directory whose expensive half is complete — exactly the case spec §119 is about.
  @Test func aFailedPullKeepsItsStagingSoTheRetryResumes() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"), withNVRAM: true)
      let nvramDigest = try #require(published.nvramDigest)
      harness.registry.failBlobGet(digest: nvramDigest, status: 500, times: 8)

      await #expect(throws: ImageError.self) {
        try await harness.images.pull(reference: published.reference.description)
      }

      let row = try #require(try await harness.imageRows.get(digest: published.manifestDigest))
      #expect(row.state == .invalid)
      let staging = harness.stagingDirectory(for: published.manifestDigest)
      #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
      #expect(
        FileManager.default.fileExists(
          atPath: staging.appending(path: "disk.img.partial").path(percentEncoded: false)))

      harness.registry.clearBlobFaults()
      harness.registry.resetRecording()
      let record = try await harness.images.pull(reference: published.reference.description)

      #expect(record.state == .ready)
      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }
  }

  /// The sweep must not delete a staging directory a pull is still resuming into, however old it
  /// looks: a directory's mtime does not move while a file inside it grows.
  @Test func theStagingSweepSparesADirectoryWithARunningPullOperation() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"), withNVRAM: true)
      harness.registry.failBlobGet(digest: try #require(published.nvramDigest), status: 500, times: 8)
      await #expect(throws: ImageError.self) {
        try await harness.images.pull(reference: published.reference.description)
      }
      let staging = harness.stagingDirectory(for: published.manifestDigest)
      // A crashed daemon leaves the operation `running`; that is what protects the directory.
      let operations = GRDBOperationRepository(db: harness.database)
      _ = try await operations.restart(
        kind: ImageManager.pullOperationKind, resourceType: "image",
        resourceId: published.manifestDigest.rawValue,
        idempotencyKey: "resumable-\(published.manifestDigest.rawValue)")
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-4 * 3_600)],
        ofItemAtPath: staging.path(percentEncoded: false))

      let swept = try await harness.images.sweepStaging(olderThan: .seconds(3_600))

      #expect(swept == 0)
      #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }
  }

  @Test func concurrentPullsRespectTheConfiguredLimit() async throws {
    let configuration = M2Harness.configuration(concurrentImagePulls: 1)
    try await withHarness(configuration: configuration) { harness in
      let first = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "a"), repository: "acme/a",
        seed: 1)
      let second = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "b"), repository: "acme/b",
        seed: 9)

      async let left = harness.images.pull(reference: first.reference.description)
      async let right = harness.images.pull(reference: second.reference.description)
      let records = try await [left, right]

      #expect(Set(records.map(\.digest)).count == 2)
      #expect(await harness.images.peakActivePulls == 1)
    }
  }

  @Test func aPullIsRefusedWhenTheHostCannotSpareTheBytes() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      await harness.images.updateConfiguration(
        M2Harness.configuration(reserveDiskBytes: UInt64.max / 2))

      let error = await #expect(throws: ImageError.self) {
        try await harness.images.pull(reference: published.reference.description)
      }

      #expect(error?.code == "IMAGE_PULL_FAILED")
      let operations = try await GRDBOperationRepository(db: harness.database).list(state: .failed)
      #expect(operations.first?.errorCode == "IMAGE_INSUFFICIENT_DISK_SPACE")
      #expect(published.chunkFetches(harness.registry) == 0)
    }
  }

  @Test func pushPublishesALocalImageAndThePulledCopyKeepsItsIdentity() async throws {
    try await withHarness { harness in
      let local = try await harness.importLinuxImage()
      let target = "\(harness.registry.host)/acme/exported:v1"

      let pushed = try await harness.images.push(imageRef: M2Harness.linuxImageName, to: target)

      #expect(pushed.hasPrefix("\(harness.registry.host)/acme/exported@sha256:"))
      // The immutable reference is recorded on the push operation so `runnerctl image push
      // --wait` can report what the registry actually assigned.
      let operation = try #require(try await harness.operations().first { $0.kind == "push-image" })
      #expect(operation.state == .succeeded)
      #expect(operation.metadataJson?.contains(pushed) == true)
      let record = try await harness.images.pull(reference: pushed)
      #expect(record.digest == local.record.digest)
      // Pushing does not rename the local image; the row still answers to its imported name.
      #expect(try await harness.images.resolve(reference: M2Harness.linuxImageName)
        == local.record.digest)
    }
  }

  @Test func pullReportsTheRegistrysOwnErrorRatherThanAGenericFailure() async throws {
    try await withHarness { harness in
      let error = await #expect(throws: RegistryError.self) {
        try await harness.images.pull(reference: "\(harness.registry.host)/acme/absent:1")
      }
      #expect(error?.code == "REGISTRY_NOT_FOUND")
    }
  }

  @Test func aBareLocalNameIsStillResolvedLocally() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      #expect(try await harness.images.resolve(reference: M2Harness.linuxImageName)
        == image.record.digest)
    }
  }

  // MARK: - inspectRemote

  /// The whole point of `image.inspectRemote`: learn the virtual size a profile has to declare
  /// without paying for the disk. Only the manifest and the two config blobs may move.
  @Test func inspectRemoteReadsTheManifestAndTransfersNoDisk() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"), withNVRAM: true)
      harness.registry.resetRecording()

      let remote = try await harness.images.inspectRemote(
        reference: published.reference.description)

      #expect(remote.manifestDigest == published.manifestDigest)
      #expect(remote.reference.description.contains("@sha256:"))
      #expect(remote.metadata.virtualDiskSizeBytes == PublishedImage.diskBytes)
      #expect(remote.metadata.hasGuestAgent)
      #expect(remote.format == .runnervm)
      #expect(remote.transferBytes > 0)
      // Nothing transferred, nothing written: no chunk fetch, no row, no blob.
      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(try await harness.imageRows.list(state: nil).isEmpty)
    }
  }

  /// An agentless image is *described*, not refused. `vm create` is where `IMAGE_NO_GUEST_AGENT`
  /// belongs; an operator asking what a reference contains deserves the answer.
  @Test func inspectRemoteDescribesAnAgentlessImageInsteadOfRefusingIt() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"),
        guestAgent: false)

      let remote = try await harness.images.inspectRemote(
        reference: published.reference.description)

      #expect(!remote.metadata.hasGuestAgent)
    }
  }

  /// Resolving here must seed the same cache a pull reads, or the pull that normally follows
  /// repeats the round trip it just paid for.
  @Test func inspectRemoteSeedsTheTagResolutionCacheForTheFollowingPull() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      _ = try await harness.images.inspectRemote(reference: published.reference.description)
      let afterInspect = harness.registry.requests("GET", containing: "/manifests/").count

      _ = try await harness.images.pull(reference: published.reference.description)

      // The pull still fetches the manifest it is about to transfer from; what it must not do is
      // re-resolve the tag first. One manifest GET, not two.
      #expect(harness.registry.requests("GET", containing: "/manifests/").count == afterInspect + 1)
    }
  }

  @Test func inspectRemoteRefusesABareLocalName() async throws {
    try await withHarness { harness in
      await #expect(throws: (any Error).self) {
        try await harness.images.inspectRemote(reference: M2Harness.linuxImageName)
      }
    }
  }

  // MARK: - images.prefetch

  /// Without prefetch the transfer happens inside the first `instance.create`, so the first job
  /// after a config change waits for the whole image and looks like a runner failure.
  @Test func prefetchPullsEveryProfileImageWhenEnabled() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      var config = M2Harness.configuration(linuxImage: published.reference.description)
      config.images.prefetch = true

      // `updateConfiguration` starts the sweep itself, detached, exactly as `config apply` does;
      // waiting on the row is what proves that path runs, not just the method behind it.
      await harness.images.updateConfiguration(config)

      try await waitUntil("the profile image is prefetched") {
        try await harness.imageRows.list(state: .ready).count == 1
      }
      let rows = try await harness.imageRows.list(state: .ready)
      #expect(rows.first?.canonicalReference?.contains("@sha256:") == true)
    }
  }

  /// Off by default: prefetch turns `config apply` and daemon start into calls that reach the
  /// network, which nobody should get without asking for it.
  @Test func prefetchIsOffByDefault() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      let config = M2Harness.configuration(linuxImage: published.reference.description)
      #expect(!config.images.prefetch)

      await harness.images.updateConfiguration(config)
      // Nothing to wait on when the expectation is "no work happened", so drive the sweep directly
      // too: if the flag were ignored, this call alone would pull.
      await harness.images.prefetchProfileImages()

      #expect(try await harness.imageRows.list(state: nil).isEmpty)
      #expect(published.chunkFetches(harness.registry) == 0)
    }
  }

  /// A local image name is not something to pull, and the macOS profile in the default
  /// configuration carries one — so prefetch must skip it rather than fail the sweep.
  @Test func prefetchSkipsProfilesWhoseImageIsALocalName() async throws {
    try await withHarness { harness in
      var config = M2Harness.configuration()
      config.images.prefetch = true

      await harness.images.updateConfiguration(config)
      await harness.images.prefetchProfileImages()

      #expect(harness.registry.requests("GET", containing: "/manifests/").isEmpty)
    }
  }

  /// An unreachable reference is logged and stepped over: `runnerd` must still start, the
  /// configuration must still apply, and the profiles that *can* be prefetched still are. The
  /// reconcile tick retries the rest.
  @Test func prefetchSurvivesAReferenceThatCannotBeResolved() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      var config = M2Harness.configuration(linuxImage: "\(harness.registry.host)/acme/absent:1")
      config.profiles[1].image = published.reference.description
      config.images.prefetch = true

      await harness.images.updateConfiguration(config)

      try await waitUntil("the reachable profile image is still prefetched") {
        try await harness.imageRows.list(state: .ready).count == 1
      }
    }
  }

  /// Repeating the sweep is what the reconcile tick does every few seconds; it must cost nothing
  /// once the image is in the store.
  @Test func repeatedPrefetchMovesNoBytes() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "origin"))
      var config = M2Harness.configuration(linuxImage: published.reference.description)
      config.images.prefetch = true
      await harness.images.updateConfiguration(config)
      try await waitUntil("the first sweep lands the image") {
        try await harness.imageRows.list(state: .ready).count == 1
      }
      harness.registry.resetRecording()

      await harness.images.prefetchProfileImages()

      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(try await harness.imageRows.list(state: .ready).count == 1)
    }
  }
}
