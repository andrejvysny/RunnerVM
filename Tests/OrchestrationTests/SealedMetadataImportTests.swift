import Foundation
import ImageStore
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// `image import` used to discard everything `scripts/build-ubuntu-image.sh` sealed and rebuild
/// `ImageMetadata` from the disk size and `--os` alone. These pin the other behaviour: a sealed
/// `metadata.json` is adopted whole, and an unusable one degrades instead of failing the import.
@Suite struct SealedMetadataImportTests {
  private static let provenance = ImageMetadata.Provenance(
    baseImage: ImageMetadata.Provenance.BaseImage(
      source: "https://cloud-images.ubuntu.com/noble.img", sha256: "sha256:aa"),
    actionsRunner: ImageMetadata.Provenance.ActionsRunner(version: "2.331.0", sha256: "sha256:bb"),
    guestAgent: ImageMetadata.Provenance.GuestAgent(gitCommit: "3fb473c"),
    builder: ImageMetadata.Provenance.Builder(
      script: "scripts/build-ubuntu-image.sh", builtAt: "2026-08-26T10:00:00Z"),
    docker: ImageMetadata.Provenance.Docker(version: "5:27.3.1"),
    packageUpgrade: true, packages: ["git=1:2.43.0", "jq=1.7.1", "docker-ce=5:27.3.1"],
    kernelVersion: "6.8.0-51-generic", diskSHA256: "sha256:dd")

  /// Lays out an `<out>` directory the way the build script seals one: disk.img beside its
  /// metadata.json. `virtualDiskSizeBytes` is deliberately wrong, because the file on disk is the
  /// authority and `ImageStore` rejects a stale figure.
  private func sealed(
    _ harness: M2Harness, named: String, os: GuestOS = .linux,
    provenance: ImageMetadata.Provenance? = SealedMetadataImportTests.provenance
  ) throws -> URL {
    let directory = harness.tree.root.appending(path: named, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = directory.appending(path: "disk.img")
    FileManager.default.createFile(atPath: disk.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: disk)
    try handle.truncate(atOffset: 32 << 20)
    try handle.close()

    let metadata = ImageMetadata(
      os: os, virtualDiskSizeBytes: 1, runnerVersion: "2.331.0",
      guestAgentVersion: "v0.1.0-12-g3fb473c",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      boot: ImageMetadata.Boot(type: os == .macos ? .macos : .efi),
      capabilities: ImageMetadata.Capabilities(docker: true, ssh: true),
      provenance: provenance)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(metadata).write(to: directory.appending(path: "metadata.json"))
    return disk
  }

  @Test func aSealedMetadataFileSurvivesImport() async throws {
    try await withHarness { harness in
      let disk = try sealed(harness, named: "out-sealed")
      let image = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "ubuntu-24")

      #expect(image.record.runnerVersion == "2.331.0")
      #expect(image.record.guestAgentVersion == "v0.1.0-12-g3fb473c")
      // The sealed file itself carries docker/ssh but no explicit `guestAgent` (T6 predates it);
      // a default import (T7) stamps that field explicitly rather than leaving it nil.
      #expect(image.metadata?.capabilities
        == ImageMetadata.Capabilities(docker: true, ssh: true, guestAgent: true))
      #expect(image.metadata?.provenance == Self.provenance)
      // The measured file wins over what the sealed file claimed.
      #expect(image.record.virtualSizeBytes == 32 << 20)
      #expect(image.record.metadataJson.contains("\"provenance\""))
    }
  }

  /// Whatever `image inspect` shows has to come from the same metadata, not a second source.
  @Test func provenanceReachesTheImageDTO() async throws {
    try await withHarness { harness in
      let disk = try sealed(harness, named: "out-dto")
      _ = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "ubuntu-24")
      let dto = Mapping.image(try await harness.images.get(reference: "ubuntu-24"))

      #expect(dto.provenance?.baseImageSHA256 == "sha256:aa")
      #expect(dto.provenance?.guestAgentCommit == "3fb473c")
      #expect(dto.provenance?.packageCount == 3)
      #expect(dto.provenance?.diskSHA256 == "sha256:dd")
      #expect(dto.provenance?.builtAt == "2026-08-26T10:00:00Z")
      #expect(dto.provenance?.packageUpgrade == true)
    }
  }

  @Test func aDiskWithNoSealedMetadataStillImports() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()

      #expect(image.record.runnerVersion == nil)
      #expect(image.metadata?.provenance == nil)
      #expect(image.record.virtualSizeBytes == 32 << 20)
    }
  }

  /// A sibling file that describes a different guest is a mistake, not an instruction: the import
  /// still succeeds, with synthesised metadata, rather than sealing a linux image as macOS.
  @Test func aMismatchedSiblingIsIgnoredRatherThanFatal() async throws {
    try await withHarness { harness in
      let disk = try sealed(harness, named: "out-mismatch", os: .macos)
      let image = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "ubuntu-24")

      #expect(image.record.runnerVersion == nil)
      #expect(image.metadata?.provenance == nil)
      #expect(image.record.os == .linux)
    }
  }

  /// An explicit `--metadata` is a claim the caller made, so an unusable one fails loudly.
  @Test func anExplicitMetadataPathIsFatalWhenUnusable() async throws {
    try await withHarness { harness in
      let disk = try sealed(harness, named: "out-explicit", os: .macos)
      let sibling = disk.deletingLastPathComponent().appending(path: "metadata.json")

      let mismatch = await #expect(throws: ImageError.self) {
        _ = try await harness.images.importLocal(
          disk: disk, nvram: nil, os: .linux, name: "a", metadataPath: sibling)
      }
      #expect(mismatch?.code == "IMAGE_INCOMPATIBLE_GUEST_OS")

      let missing = await #expect(throws: ImageError.self) {
        _ = try await harness.images.importLocal(
          disk: disk, nvram: nil, os: .linux, name: "b",
          metadataPath: disk.deletingLastPathComponent().appending(path: "nope.json"))
      }
      #expect(missing?.code == "IMAGE_NOT_FOUND")
    }
  }

  /// Two imports of the same sealed directory are still one image: `createdAt` comes from the file
  /// rather than the clock, so the content digest does not move between runs.
  @Test func adoptingSealedMetadataKeepsImportIdempotent() async throws {
    try await withHarness { harness in
      let disk = try sealed(harness, named: "out-idempotent")
      let first = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "ubuntu-24")
      let second = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "ubuntu-24")

      #expect(first.record.digest == second.record.digest)
      #expect(try await harness.images.list().count == 1)
    }
  }

  // MARK: - `--no-guest-agent` (T7)

  @Test func defaultImportWritesAnExplicitGuestAgentTrue() async throws {
    try await withHarness { harness in
      let disk = try harness.sparseFile(named: "no-sealed.img", bytes: 32 << 20)
      let image = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "no-sealed")
      #expect(image.metadata?.capabilities.guestAgent == true)
      #expect(image.metadata?.hasGuestAgent == true)
    }
  }

  @Test func noGuestAgentWritesFalseAndHasGuestAgentIsFalse() async throws {
    try await withHarness { harness in
      let disk = try harness.sparseFile(named: "no-agent.img", bytes: 32 << 20)
      let image = try await harness.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "no-agent", guestAgent: false)
      #expect(image.metadata?.capabilities.guestAgent == false)
      #expect(image.metadata?.hasGuestAgent == false)
    }
  }

  /// A sealed file that predates `capabilities.guestAgent` (T6) has no explicit field; the
  /// fallback trusts a recorded guest agent version, since no build without an agent would ever
  /// have set one. This tests `ImageMetadata.hasGuestAgent` itself, not the import path -- the
  /// field an explicit `--no-guest-agent`/default import would stamp is a separate concern
  /// (see the two tests above).
  @Test func legacyMetadataWithAGuestAgentVersionButNoExplicitFieldFallsBackToTrue() {
    let metadata = ImageMetadata(
      os: .linux, virtualDiskSizeBytes: 1, guestAgentVersion: "v0.1.0-12-g3fb473c",
      createdAt: Date(timeIntervalSince1970: 0), boot: ImageMetadata.Boot(type: .efi))
    #expect(metadata.capabilities.guestAgent == nil)
    #expect(metadata.hasGuestAgent == true)
  }

  @Test func legacyMetadataWithNeitherFallsBackToFalse() {
    let metadata = ImageMetadata(
      os: .linux, virtualDiskSizeBytes: 1, createdAt: Date(timeIntervalSince1970: 0),
      boot: ImageMetadata.Boot(type: .efi))
    #expect(metadata.capabilities.guestAgent == nil)
    #expect(metadata.hasGuestAgent == false)
  }
}
