import Foundation
import RunnerCore
import Testing
@testable import ImageStore

@Suite struct ImageStoreTests {
  @Test func importIsIdempotentByContent() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let metadata = TempStore.linuxMetadata()

    let first = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: metadata, name: "ubuntu-24"
    )
    let second = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: metadata, name: "other-name"
    )

    #expect(first.digest == second.digest)
    #expect(first.created)
    #expect(!second.created)
    #expect(first.digest.sha256Hex != nil)
    #expect(try env.blobFiles().count == 1)
    #expect(try await env.images.list().count == 1)
    // The manifest is immutable, so the first import's name survives.
    #expect(second.manifest.name == "ubuntu-24")
  }

  @Test func importLeavesNoStagingBehind() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    _ = try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
    #expect(try env.stagingChildren(of: env.paths.imagesDir).isEmpty)
  }

  @Test func inspectReportsVirtualAndAllocated() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let metadata = TempStore.linuxMetadata()
    let imported = try await env.images.importLocal(disk: disk, nvram: nil, metadata: metadata)

    let info = try await env.images.inspect(digest: imported.digest)
    #expect(info.virtualBytes == TempStore.diskBytes)
    #expect(info.metadata == metadata)
    #expect(info.manifest.layers.count == 1)
    #expect(info.manifest.layer(.disk)?.sizeBytes == TempStore.diskBytes)
    // Sparse: only the written block plus the two JSON files are actually committed.
    #expect(info.allocatedBytes < 1 << 20)
    #expect(info.allocatedBytes > 0)
  }

  @Test func publishedImageIsReadOnly() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let imported = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: TempStore.linuxMetadata()
    )

    let directory = try #require(env.images.manifestDirectory(for: imported.digest))
    #expect(try env.mode(of: directory) == 0o555)
    #expect(try env.mode(of: directory.appending(path: "manifest.json")) == 0o444)
    #expect(try env.mode(of: directory.appending(path: "metadata.json")) == 0o444)
    #expect(try env.mode(of: try await env.images.blobURL(role: .disk, digest: imported.digest)) == 0o444)
  }

  @Test func manifestOnDiskMatchesReturnedManifest() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let imported = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: TempStore.linuxMetadata()
    )

    let directory = try #require(env.images.manifestDirectory(for: imported.digest))
    let onDisk = try CanonicalJSON.decode(
      LocalImageManifest.self, from: try FileSystem.read(directory.appending(path: "manifest.json"))
    )
    #expect(onDisk == imported.manifest)
    #expect(directory.lastPathComponent == "sha256-\(try #require(imported.digest.sha256Hex))")
  }

  @Test func nvramIsStoredAsASecondLayer() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let nvram = try env.makeSparseDisk(named: "src.nvram", virtualBytes: 4096, marker: 0x11)
    let imported = try await env.images.importLocal(
      disk: disk, nvram: nvram, metadata: TempStore.linuxMetadata()
    )
    #expect(imported.manifest.layers.map(\.role) == [.disk, .nvram])
    #expect(try env.blobFiles().count == 2)
    #expect(FileSystem.exists(try await env.images.blobURL(role: .nvram, digest: imported.digest)))
  }

  @Test func importRejectsDiskSizeMismatch() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let metadata = TempStore.linuxMetadata(virtualDiskSizeBytes: TempStore.diskBytes + 1)
    await #expect(throws: ImageError.self) {
      try await env.images.importLocal(disk: disk, nvram: nil, metadata: metadata)
    }
  }

  @Test func macOSImageRequiresHardwareModelAndAuxStorage() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let nvram = try env.makeSparseDisk(named: "aux.bin", virtualBytes: 4096, marker: 0x22)

    await #expect(throws: ImageError.self) {
      try await env.images.importLocal(
        disk: disk, nvram: nvram, metadata: TempStore.macOSMetadata(hardwareModel: nil)
      )
    }
    await #expect(throws: ImageError.self) {
      try await env.images.importLocal(
        disk: disk, nvram: nil, metadata: TempStore.macOSMetadata(hardwareModel: "bW9kZWw=")
      )
    }
    let ok = try await env.images.importLocal(
      disk: disk, nvram: nvram, metadata: TempStore.macOSMetadata(hardwareModel: "bW9kZWw="), name: "macos-15"
    )
    #expect(ok.created)
    #expect(ok.manifest.os == .macos)
  }

  @Test func verifyDetectsACorruptBlob() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let imported = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: TempStore.linuxMetadata()
    )
    try await env.images.verify(digest: imported.digest)

    let blob = try await env.images.blobURL(role: .disk, digest: imported.digest)
    try FileSystem.setMode(0o644, at: blob)
    try env.overwrite(blob, at: 0, with: Data(repeating: 0xFF, count: 8))
    try FileSystem.setMode(0o444, at: blob)

    await #expect(throws: ImageError.self) { try await env.images.verify(digest: imported.digest) }
  }

  @Test func deleteReclaimsOnlyUnreferencedBlobs() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    // Same bytes, different metadata: two image identities sharing one blob.
    let a = try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
    let b = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: TempStore.linuxMetadata(runnerVersion: "2.320.0")
    )
    #expect(a.digest != b.digest)
    #expect(try env.blobFiles().count == 1)

    try await env.images.delete(digest: a.digest)
    #expect(try env.blobFiles().count == 1)
    #expect(try await env.images.list().map(\.digest) == [b.digest])

    try await env.images.delete(digest: b.digest)
    #expect(try env.blobFiles().isEmpty)
    #expect(try await env.images.list().isEmpty)
    // Idempotent.
    try await env.images.delete(digest: b.digest)
    await #expect(throws: ImageError.self) { try await env.images.inspect(digest: b.digest) }
  }

  @Test func unreferencedBlobsFindsCrashOrphans() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "src.img")
    let imported = try await env.images.importLocal(
      disk: disk, nvram: nil, metadata: TempStore.linuxMetadata()
    )
    #expect(try await env.images.unreferencedBlobs().isEmpty)

    // Exactly what a crash between blob publication and manifest rename leaves behind.
    let hex = String(repeating: "ab", count: 32)
    let orphan = env.paths.imageBlobsDir
      .appending(path: "sha256/\(hex.prefix(2))", directoryHint: .isDirectory).appending(path: hex)
    try FileSystem.ensureDirectory(orphan.deletingLastPathComponent())
    try FileSystem.write(Data("orphan".utf8), to: orphan, mode: 0o444)

    #expect(try await env.images.unreferencedBlobs().map(\.lastPathComponent) == [hex])
    try await env.images.delete(digest: imported.digest)
    #expect(try env.blobFiles().isEmpty)
  }

  @Test func sweepStagingDropsStaleDirectories() async throws {
    let env = try TempStore()
    let staging = env.paths.imagesDir.appending(path: ".tmp/leftover", directoryHint: .isDirectory)
    try FileSystem.ensureDirectory(staging, permissions: 0o700)

    #expect(try await env.images.sweepStaging(olderThan: .seconds(3600)) == 0)
    let later = Date().addingTimeInterval(7200)
    #expect(try await env.images.sweepStaging(olderThan: .seconds(3600), now: later) == 1)
    #expect(!FileSystem.exists(staging))
  }
}
