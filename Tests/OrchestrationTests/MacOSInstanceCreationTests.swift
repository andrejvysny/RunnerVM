import Foundation
import ImageStore
import RunnerCore
import Testing

@testable import Orchestration

/// M8.1: what a macOS image has to declare before an instance may be created from it, and what of
/// that reaches `spec.json`. The VM itself is still a `FakeWorker` — no macOS guest boots yet.
@Suite struct MacOSInstanceCreationTests {
  private static let hardwareModel = Data("fake-hardware-model".utf8).base64EncodedString()

  /// Seals a macOS image the way a real one arrives: `disk.img` + `nvram.bin` (the auxiliary
  /// storage) + a `metadata.json` carrying the platform block. `importLocal` cannot set the sizing
  /// floors directly, and adopting a sealed file is the path a tart import takes anyway.
  private func importMacImage(
    _ harness: M2Harness, named: String, minimumCPUCount: Int? = 1,
    minimumMemoryBytes: UInt64? = ByteSize.mebibytes(512).bytes,
    diskBytes: UInt64 = ByteSize.gibibytes(1).bytes
  ) async throws -> ManagedImage {
    let directory = harness.tree.root.appending(path: named, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = try Self.sparseFile(at: directory.appending(path: "disk.img"), bytes: diskBytes)
    let nvram = try Self.sparseFile(at: directory.appending(path: "nvram.bin"), bytes: 64 << 10)

    let metadata = ImageMetadata(
      os: .macos, virtualDiskSizeBytes: diskBytes, createdAt: M2Harness.imageClock,
      boot: ImageMetadata.Boot(type: .macos),
      macos: ImageMetadata.MacOSPlatform(
        hardwareModel: Self.hardwareModel, sourceVersion: "26.0",
        minimumCPUCount: minimumCPUCount, minimumMemoryBytes: minimumMemoryBytes))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let metadataURL = directory.appending(path: "metadata.json")
    try encoder.encode(metadata).write(to: metadataURL)

    return try await harness.images.importLocal(
      disk: disk, nvram: nvram, os: .macos, name: M2Harness.macImageName,
      metadataPath: metadataURL)
  }

  private static func sparseFile(at url: URL, bytes: UInt64) throws -> URL {
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: bytes)
    try handle.close()
    return url
  }

  /// The `mac` profile is 4 vCPU / 2 GiB (`M2Harness.configuration`).
  @Test func aProfileBelowTheImagesCPUFloorIsRefusedBeforeAnyRowExists() async throws {
    try await withHarness { harness in
      let image = try await importMacImage(harness, named: "mac-cpu", minimumCPUCount: 6)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_PROFILE_CPU_TOO_SMALL")
      #expect(try await harness.instances.list().isEmpty)
      // The planning pin was released, so `image.prune` can still reclaim the digest.
      #expect(try await harness.imageRows.pinCount(digest: image.record.digest) == 0)
    }
  }

  @Test func aProfileBelowTheImagesMemoryFloorIsRefused() async throws {
    try await withHarness { harness in
      _ = try await importMacImage(
        harness, named: "mac-memory", minimumCPUCount: 4,
        minimumMemoryBytes: ByteSize.gibibytes(4).bytes)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_PROFILE_MEMORY_TOO_SMALL")
      #expect(try await harness.instances.list().isEmpty)
    }
  }

  @Test func theImagesPlatformBlockReachesTheWorkersSpec() async throws {
    try await withHarness { harness in
      _ = try await importMacImage(
        harness, named: "mac-ok", minimumCPUCount: 2,
        minimumMemoryBytes: ByteSize.gibibytes(1).bytes)

      let record = try await harness.instances.create(profileName: "mac")

      #expect(record.state == .waitingForAgent)
      let specURL = harness.paths.instanceDir(record.id).appending(path: "spec.json")
      let spec = try JSONDecoder().decode(
        InstanceSpecFile.self, from: try Data(contentsOf: specURL))
      #expect(spec.os == .macos)
      #expect(spec.macos?.hardwareModel == Self.hardwareModel)
      #expect(spec.macos?.sourceVersion == "26.0")
      #expect(spec.macos?.minimumCPUCount == 2)
      #expect(spec.macos?.minimumMemoryBytes == ByteSize.gibibytes(1).bytes)
    }
  }

  /// A Linux instance's spec must be untouched by all of the above.
  @Test func aLinuxSpecStillCarriesNoPlatformBlock() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")

      let specURL = harness.paths.instanceDir(record.id).appending(path: "spec.json")
      let json = String(decoding: try Data(contentsOf: specURL), as: UTF8.self)
      #expect(!json.contains("macos"))
    }
  }

  /// The host truncates `disk.img` up before boot and the *guest* is what turns that into
  /// filesystem — which a macOS guest cannot do (`agent.resizeDisk` answers `NOT_SUPPORTED`). A
  /// profile promising more than the image carries is refused before the row exists, rather than
  /// handing the job a 100 GiB raw disk and a 60 GiB root volume.
  @Test func aProfileAskingForMoreDiskThanTheImageCarriesIsRefused() async throws {
    try await withHarness { harness in
      // The `mac` profile is 1 GiB of disk (`M2Harness.configuration`).
      let image = try await importMacImage(
        harness, named: "mac-small-disk", diskBytes: ByteSize.mebibytes(512).bytes)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_DISK_RESIZE_UNSUPPORTED")
      #expect(error?.retryable == false)
      #expect(try await harness.instances.list().isEmpty)
      #expect(try await harness.imageRows.pinCount(digest: image.record.digest) == 0)
    }
  }

  /// The other direction is refused at admission too. `InstanceStore.materialize` would catch it
  /// (`IMAGE_DISK_SMALLER_THAN_IMAGE`), but only after the row and its reservation exist.
  @Test func aProfileAskingForLessDiskThanTheImageIsRefusedBeforeAnyRowExists() async throws {
    try await withHarness { harness in
      _ = try await importMacImage(
        harness, named: "mac-big-disk", diskBytes: ByteSize.gibibytes(4).bytes)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_DISK_RESIZE_UNSUPPORTED")
      #expect(try await harness.instances.list().isEmpty)
    }
  }

  /// An image that states no sizing floor would move the first real compatibility failure out of
  /// admission and into `VZVirtualMachineConfiguration.validate()`, inside a worker, after a clone
  /// and a boot. macOS images have to declare both.
  @Test func aMacOSImageWithNoSizingFloorsIsRefused() async throws {
    try await withHarness { harness in
      _ = try await importMacImage(
        harness, named: "mac-no-cpu-floor", minimumCPUCount: nil)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_IMAGE_MINIMUMS_MISSING")
      #expect(try await harness.instances.list().isEmpty)
    }
  }

  @Test func aMacOSImageWithNoMemoryFloorIsRefused() async throws {
    try await withHarness { harness in
      _ = try await importMacImage(
        harness, named: "mac-no-memory-floor", minimumMemoryBytes: nil)

      let error = await #expect(throws: VMError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }

      #expect(error?.code == "VM_MACOS_IMAGE_MINIMUMS_MISSING")
    }
  }

  /// The floor under all of it: `ImageStore` will not even store a macOS image that cannot say what
  /// hardware it is, so `plan` is a second line of defence rather than the only one.
  @Test func aMacOSImageWithNoHardwareModelCannotBeImported() async throws {
    try await withHarness { harness in
      let disk = try harness.sparseFile(named: "no-model.img", bytes: 32 << 20)
      let nvram = try harness.sparseFile(named: "no-model-nvram.bin", bytes: 64 << 10)

      let error = await #expect(throws: ImageError.self) {
        _ = try await harness.images.importLocal(
          disk: disk, nvram: nvram, os: .macos, name: "no-model")
      }

      #expect(error?.code == "IMAGE_METADATA_INVALID")
    }
  }
}
