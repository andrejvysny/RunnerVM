import DaemonAPI
import Foundation
import ImageStore
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Spec §58: a tart image is importable but never runnable. These go through the real
/// `ImageManager`/`InstanceManager` against a `FakeRegistry` holding a tart-shaped artifact.
@Suite struct TartImportTests {
  private static let repository = "cirruslabs/ubuntu"

  private func publishTart(
    _ harness: M2Harness, name: String = "tart-origin", tag: String = "latest"
  ) throws -> TartImagePublisher.Published {
    let directory = harness.tree.root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = try PublishedImage.makeDisk(at: directory.appending(path: "disk.img"), seed: 3)
    let nvram = directory.appending(path: "nvram.bin")
    try Data(repeating: 0x5A, count: 64 << 10).write(to: nvram)
    return try TartImagePublisher.publish(
      into: harness.registry, diskURL: disk, nvramURL: nvram,
      staging: directory.appending(path: "publish", directoryHint: .isDirectory),
      repository: Self.repository, tag: tag, chunkBytes: PublishedImage.chunkBytes,
      // Fixed, so the imported image's content digest does not depend on when the test ran.
      uploadTime: M2Harness.imageClock)
  }

  private func chunkFetches(_ harness: M2Harness, _ published: TartImagePublisher.Published) -> Int {
    harness.registry.requests("GET", containing: "/blobs/").count { request in
      published.chunkDigests.contains { request.path.hasSuffix($0) }
    }
  }

  /// A tag reference into the fake, known before the harness exists so a profile can name it.
  private func tartReference(_ fake: FakeRegistry, tag: String = "latest") -> String {
    "\(fake.host)/\(Self.repository):\(tag)"
  }

  // MARK: - Pull

  @Test func pullImportsATartImageAsANativeRunnerVMImage() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness)

      let record = try await harness.images.pull(reference: published.reference.description)

      #expect(record.state == .ready)
      #expect(
        record.canonicalReference?.hasSuffix("@\(published.manifestDigest.rawValue)") == true)
      #expect(record.runnerVersion == nil)
      #expect(record.guestAgentVersion == nil)
      let managed = try await harness.images.get(reference: record.digest.rawValue)
      let metadata = try #require(managed.metadata)
      #expect(metadata.virtualDiskSizeBytes == published.virtualBytes)
      #expect(metadata.hasGuestAgent == false)
      #expect(metadata.provenance?.imported?.format == "tart")
      #expect(metadata.provenance?.imported?.manifestDigest == published.manifestDigest.rawValue)
      #expect(metadata.provenance?.imported?.tartConfig?.cpuCount == 4)
      // The transient row keyed by the tart manifest digest is gone once the real one lands.
      #expect(try await harness.imageRows.list(state: nil).map(\.state) == [.ready])
    }
  }

  @Test func aForcedRunnerVMFormatRefusesATartReferenceWithNoOperationRow() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness)

      await #expect(throws: RegistryError.self) {
        _ = try await harness.images.startPull(
          reference: published.reference.description, format: .runnervm)
      }

      #expect(try await pullOperations(harness).isEmpty)
      #expect(try await harness.imageRows.list(state: nil).isEmpty)
      #expect(chunkFetches(harness, published) == 0)
    }
  }

  /// The import is one-way: what goes back out is a RunnerVM artifact, with the tart origin kept
  /// as provenance rather than as a format the image can still be read as.
  @Test func pushingAnImportedImageRepublishesItInRunnerVMFormat() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness)
      let record = try await harness.images.pull(reference: published.reference.description)

      let pushed = try await harness.images.push(
        imageRef: record.digest.rawValue, to: "\(harness.registry.host)/acme/reexported:v1")

      let remote = try await RunnerVMImageTransfer.inspect(
        try OCIReference(parsing: pushed), registry: harness.registry.makeClient())
      #expect(remote.format == .runnervm)
      #expect(remote.metadata.provenance?.imported?.format == "tart")
      #expect(
        remote.metadata.provenance?.imported?.manifestDigest == published.manifestDigest.rawValue)
      #expect(remote.metadata.hasGuestAgent == false)
    }
  }

  // MARK: - The guardrail

  @Test func vmCreateOnACachedTartImageIsRefusedAndLeavesNoPin() async throws {
    let fake = FakeRegistry()
    let reference = tartReference(fake)
    try await withHarness(
      configuration: M2Harness.configuration(linuxImage: reference), registry: fake
    ) { harness in
      let published = try publishTart(harness)
      _ = try await harness.images.pull(reference: reference)
      harness.registry.resetRecording()

      let error = await #expect(throws: ImageError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }

      #expect(error?.code == "IMAGE_NO_GUEST_AGENT")
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
      #expect(try await harness.instanceRows.list(profile: nil, states: nil).isEmpty)
      #expect(chunkFetches(harness, published) == 0)
    }
  }

  /// The remote case: nothing at all should be written before the refusal — no transfer, no
  /// operation row, no `pulling` row, no staging directory and no pin.
  @Test func vmCreateOnARemoteTartImageIsRefusedBeforeAnyDiskByteMoves() async throws {
    let fake = FakeRegistry()
    let reference = tartReference(fake)
    try await withHarness(
      configuration: M2Harness.configuration(linuxImage: reference), registry: fake
    ) { harness in
      let published = try publishTart(harness)
      harness.registry.resetRecording()

      let error = await #expect(throws: ImageError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }

      #expect(error?.code == "IMAGE_NO_GUEST_AGENT")
      #expect(chunkFetches(harness, published) == 0)
      // Only the OCI config and the tart config layer were ever fetched.
      #expect(harness.registry.requests("GET", containing: "/blobs/").count == 2)
      #expect(try await harness.imageRows.list(state: nil).isEmpty)
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
      #expect(try await pullOperations(harness).isEmpty)
      let staging = harness.stagingDirectory(for: published.manifestDigest)
      #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }
  }

  /// An image sealed before `capabilities.guestAgent` existed is trusted when it recorded a guest
  /// agent version -- no build without an agent would ever have set that -- so the new guardrail
  /// must not lock those images out.
  @Test func aLegacyImageWithOnlyAGuestAgentVersionStillReserves() async throws {
    try await withHarness { harness in
      let digest = try await importLegacyImage(harness)

      let (reserved, _) = try await harness.images.reserve(
        reference: "legacy", for: InstanceID.generate())

      #expect(reserved == digest)
      #expect(try await harness.imageRows.pins(ownerType: .planning).count == 1)
    }
  }

  // MARK: - config.validate / config.apply

  @Test func configValidateReportsAndConfigApplyRefusesAnAgentlessProfileImage() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness)
      let record = try await harness.images.pull(reference: published.reference.description)
      let configuration = M2Harness.configuration(
        linuxImage: try #require(record.canonicalReference))
      let service = harness.service(parseConfig: { _ in configuration })

      let validated = try await service.configValidate(ConfigValidateRequest(yaml: "-"))

      let issue = try #require(validated.issues.first(code: "PROFILE_IMAGE_NO_GUEST_AGENT"))
      #expect(issue.severity == .error)
      #expect(issue.path == "profiles[0].image")
      await #expect(throws: ConfigurationError.self) {
        _ = try await service.configApply(ConfigApplyRequest(yaml: "-"))
      }
    }
  }

  @Test func configValidateIsSilentAboutAnImageThisHostHasNotPulled() async throws {
    let fake = FakeRegistry()
    let reference = tartReference(fake)
    try await withHarness(registry: fake) { harness in
      _ = try publishTart(harness)
      let configuration = M2Harness.configuration(linuxImage: reference)
      let service = harness.service(parseConfig: { _ in configuration })

      let validated = try await service.configValidate(ConfigValidateRequest(yaml: "-"))

      #expect(!validated.issues.contains(code: "PROFILE_IMAGE_NO_GUEST_AGENT"))
    }
  }

  // MARK: - Helpers

  /// Only `pull-image` rows: the harness seeds an `apply-config` operation of its own.
  private func pullOperations(_ harness: M2Harness) async throws -> [OperationRecord] {
    try await GRDBOperationRepository(db: harness.database).list(state: nil)
      .filter { $0.kind == ImageManager.pullOperationKind }
  }

  /// Goes around `ImageManager.importLocal`, which always stamps `capabilities.guestAgent`, to
  /// produce the pre-T7 shape: a guest agent version and nothing explicit.
  private func importLegacyImage(_ harness: M2Harness) async throws -> ImageDigest {
    let metadata = ImageMetadata(
      os: .linux, virtualDiskSizeBytes: 32 << 20, guestAgentVersion: "0.1.0",
      createdAt: M2Harness.imageClock, boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(docker: false, ssh: true, guestAgent: nil))
    let disk = try harness.sparseFile(named: "legacy.img", bytes: 32 << 20)
    let imported = try await harness.imageStore.importLocal(
      disk: disk, nvram: nil, metadata: metadata, name: "legacy")
    let info = try await harness.imageStore.inspect(digest: imported.digest)
    try await harness.imageRows.upsert(
      ImageRecord(
        digest: imported.digest, canonicalReference: "legacy", os: .linux, architecture: "arm64",
        schemaVersion: info.metadata.schemaVersion,
        metadataJson: String(
          decoding: try JSONEncoder.imageMetadata().encode(info.metadata), as: UTF8.self),
        localPath: imported.manifestDirectory.path(percentEncoded: false),
        virtualSizeBytes: info.virtualBytes, guestAgentVersion: "0.1.0", state: .ready,
        createdAt: DatabaseDate(info.metadata.createdAt)))
    return imported.digest
  }
}
