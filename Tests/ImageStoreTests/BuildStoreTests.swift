import Foundation
import RunnerCore
import Testing
@testable import ImageStore

@Suite struct BuildStoreTests {
  private func importBase(_ env: TempStore) async throws -> ImportedImage {
    let disk = try env.makeSparseDisk(named: "base.img")
    return try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
  }

  @Test func materializeFromImageClonesTheDiskAndWritesSpecAndLock() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()
    let id = ImageBuildID.generate()

    let layout = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    #expect(FileSystem.exists(layout.disk))
    #expect(try env.mode(of: layout.disk) == 0o600)
    #expect(try FileSystem.fileSize(at: layout.disk) == TempStore.diskBytes)
    #expect(FileSystem.exists(layout.spec))
    let specContent = try String(decoding: FileSystem.read(layout.spec), as: UTF8.self)
    #expect(specContent.contains(id.rawValue))
    #expect(FileSystem.exists(layout.workerLock))
    #expect(try env.mode(of: layout.workerLock) == 0o600)
    #expect(layout.nvram == nil)
    #expect(await store.layout(for: id).directory == layout.directory)
  }

  @Test func materializeTruncatesUpWhenDiskBytesExceedsTheImage() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()
    let id = ImageBuildID.generate()

    let layout = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes * 2,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    #expect(try FileSystem.fileSize(at: layout.disk) == TempStore.diskBytes * 2)
    #expect(await store.allocatedBytes(buildId: id) < 1 << 20)
  }

  @Test func materializeRefusesADiskSmallerThanTheImage() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()

    await #expect(throws: ImageError.self) {
      try await store.materialize(
        buildId: .generate(), from: image.digest, diskBytes: TempStore.diskBytes / 2,
        spec: SampleSpec(instanceId: "small")
      )
    }
  }

  @Test func nvramIsClonedWhenTheImageHasOne() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let nvram = try env.makeSparseDisk(named: "base.nvram", virtualBytes: 4_096, marker: 0x33)
    let image = try await env.images.importLocal(
      disk: disk, nvram: nvram, metadata: TempStore.linuxMetadata())
    let store = env.buildStore()
    let id = ImageBuildID.generate()

    let layout = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    let clonedNVRAM = try #require(layout.nvram)
    #expect(FileSystem.exists(clonedNVRAM))
    #expect(try env.mode(of: clonedNVRAM) == 0o600)
  }

  @Test func materializeFromRawDiskHasNoNVRAM() async throws {
    let env = try TempStore()
    let raw = try env.makeSparseDisk(named: "raw.img")
    let store = env.buildStore()
    let id = ImageBuildID.generate()

    let layout = try await store.materialize(
      buildId: id, fromRawDisk: raw, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    #expect(FileSystem.exists(layout.disk))
    #expect(layout.nvram == nil)
  }

  @Test func materializeRefusesToOverwriteAPublishedBuild() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()
    let id = ImageBuildID.generate()
    _ = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    await #expect(throws: ImageError.self) {
      try await store.materialize(
        buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
        spec: SampleSpec(instanceId: id.rawValue)
      )
    }
  }

  @Test func deleteIsIdempotentAndListingSkipsStaging() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()
    let id = ImageBuildID.generate()
    _ = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    try FileSystem.ensureDirectory(
      env.paths.buildsDir.appending(path: ".tmp/other", directoryHint: .isDirectory), permissions: 0o700
    )

    #expect(try await store.listDirectories() == [id])
    try await store.delete(buildId: id)
    #expect(try await store.listDirectories().isEmpty)
    // Idempotent.
    try await store.delete(buildId: id)
    try await store.delete(buildId: .generate())
  }

  @Test func workerLockIsUnheldRightAfterMaterialization() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.buildStore()
    let id = ImageBuildID.generate()
    _ = try await store.materialize(
      buildId: id, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    #expect(try await store.workerLockHolder(buildId: id) == nil)
  }

  // MARK: - VMDirectoryStaging byte-identical layout

  /// `InstanceStore.materialize` and `BuildStore.materialize` both delegate to
  /// `VMDirectoryStaging.stage`; this pins that the two clone directories end up with the same
  /// file names and sizes, so a refactor of one cannot silently drift from the other.
  @Test func instanceAndBuildDirectoriesHaveIdenticalLayoutAfterMaterialize() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let nvram = try env.makeSparseDisk(named: "base.nvram", virtualBytes: 4_096, marker: 0x33)
    let image = try await env.images.importLocal(
      disk: disk, nvram: nvram, metadata: TempStore.linuxMetadata())

    let instanceStore = env.instanceStore()
    let instanceId = InstanceID.generate()
    let instanceResult = try await instanceStore.materialize(
      instanceId: instanceId, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: instanceId.rawValue)
    )

    let buildStore = env.buildStore()
    let buildId = ImageBuildID.generate()
    let buildLayout = try await buildStore.materialize(
      buildId: buildId, from: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: buildId.rawValue)
    )

    let instanceEntries = try Self.listing(of: instanceResult.layout.directory)
    let buildEntries = try Self.listing(of: buildLayout.directory)
    #expect(instanceEntries == buildEntries)
  }

  /// `{name: size}` for every regular file directly inside `directory`, ignoring the two spec
  /// files' content (which legitimately differ -- an instance id versus a build id).
  private static func listing(of directory: URL) throws -> [String: UInt64] {
    var result: [String: UInt64] = [:]
    for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where child.lastPathComponent != VMInstanceLayout.specName {
      result[child.lastPathComponent] = try FileSystem.fileSize(at: child)
    }
    return result
  }
}
