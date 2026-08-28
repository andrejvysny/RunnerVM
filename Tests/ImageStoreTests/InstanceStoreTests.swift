import Foundation
import RunnerCore
import Testing
@testable import ImageStore

@Suite struct InstanceStoreTests {
  private func importBase(_ env: TempStore) async throws -> ImportedImage {
    let disk = try env.makeSparseDisk(named: "base.img")
    return try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
  }

  /// vmworker mints `machine-identifier.bin` for a macOS instance; the daemon and the sealer agree
  /// on its name through this constant alone, so the name is pinned here rather than duplicated.
  @Test func theLayoutNamesTheMacOSMachineIdentifier() {
    #expect(VMInstanceLayout.machineIdentifierName == "machine-identifier.bin")

    let directory = URL(fileURLWithPath: "/tmp/rvm-instance")
    let layout = VMInstanceLayout(
      instanceId: InstanceID.generate(), directory: directory, hasNVRAM: true)

    #expect(layout.machineIdentifier == directory.appending(path: "machine-identifier.bin"))
    #expect(!VMInstanceLayout.diagnosticNames.contains(VMInstanceLayout.machineIdentifierName))
  }

  @Test func cloneProducesIndependentInstances() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let blob = try await env.images.blobURL(role: .disk, digest: image.digest)
    let blobHashBefore = try SHA256Hasher.hashFile(at: blob)

    var layouts: [VMInstanceLayout] = []
    for _ in 0..<3 {
      let id = InstanceID.generate()
      let result = try await store.materialize(
        instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
        spec: SampleSpec(instanceId: id.rawValue)
      )
      #expect(result.cloneMethod == .apfsCoW)
      layouts.append(result.layout)
    }

    try env.overwrite(layouts[0].disk, at: 4096, with: Data(repeating: 0xAB, count: 4096))
    let hashes = try layouts.map { try SHA256Hasher.hashFile(at: $0.disk) }
    #expect(hashes[1] == hashes[2])
    #expect(hashes[0] != hashes[1])
    #expect(try SHA256Hasher.hashFile(at: blob) == blobHashBefore)

    for layout in layouts {
      #expect(FileSystem.exists(layout.workerLock))
      #expect(try env.mode(of: layout.workerLock) == 0o600)
      #expect(try env.mode(of: layout.disk) == 0o600)
      #expect(FileSystem.exists(layout.spec))
      #expect(layout.nvram == nil)
      #expect(try FileSystem.fileSize(at: layout.disk) == TempStore.diskBytes)
      #expect(await store.allocatedBytes(instanceId: layout.instanceId) < 1 << 20)
    }
    #expect(try env.stagingChildren(of: env.paths.instancesDir).isEmpty)
  }

  @Test func diskGrowsButNeverShrinks() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()

    let grown = InstanceID.generate()
    let result = try await store.materialize(
      instanceId: grown, image: image.digest, diskBytes: TempStore.diskBytes * 2,
      spec: SampleSpec(instanceId: grown.rawValue)
    )
    #expect(try FileSystem.fileSize(at: result.layout.disk) == TempStore.diskBytes * 2)
    // Truncating a sparse raw disk upward costs nothing; the guest agent grows the filesystem.
    #expect(await store.allocatedBytes(instanceId: grown) < 1 << 20)

    await #expect(throws: ImageError.self) {
      try await store.materialize(
        instanceId: InstanceID.generate(), image: image.digest, diskBytes: TempStore.diskBytes / 2,
        spec: SampleSpec(instanceId: "small")
      )
    }
  }

  @Test func nvramIsClonedWhenTheImageHasOne() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let nvram = try env.makeSparseDisk(named: "base.nvram", virtualBytes: 4096, marker: 0x33)
    let image = try await env.images.importLocal(
      disk: disk, nvram: nvram, metadata: TempStore.linuxMetadata()
    )
    let store = env.instanceStore()

    let id = InstanceID.generate()
    let result = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    let clonedNVRAM = try #require(result.layout.nvram)
    #expect(FileSystem.exists(clonedNVRAM))
    #expect(try env.mode(of: clonedNVRAM) == 0o600)
    #expect(await store.layout(for: id).nvram != nil)
  }

  @Test func failureMidwayLeavesOnlyStaging() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let id = InstanceID.generate()

    await #expect(throws: (any Error).self) {
      try await store.materialize(
        instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes, spec: ThrowingSpec()
      )
    }
    #expect(!FileSystem.exists(env.paths.instanceDir(id)))
    let staging = try env.stagingChildren(of: env.paths.instancesDir)
    #expect(staging.map(\.lastPathComponent) == [id.rawValue])
    #expect(FileSystem.exists(staging[0].appending(path: "disk.img")))
    #expect(try await store.listDirectories().isEmpty)

    // Retrying the same id clears the dead attempt and publishes normally.
    let retried = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    #expect(FileSystem.exists(retried.layout.directory))
    #expect(try env.stagingChildren(of: env.paths.instancesDir).isEmpty)
  }

  @Test func materializeRefusesToOverwriteAPublishedInstance() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let id = InstanceID.generate()
    _ = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    await #expect(throws: ImageError.self) {
      try await store.materialize(
        instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
        spec: SampleSpec(instanceId: id.rawValue)
      )
    }
  }

  @Test func deleteIsIdempotentAndListingSkipsStaging() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let id = InstanceID.generate()
    _ = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    try FileSystem.ensureDirectory(
      env.paths.instancesDir.appending(path: ".tmp/other", directoryHint: .isDirectory), permissions: 0o700
    )

    #expect(try await store.listDirectories() == [id])
    try await store.delete(instanceId: id)
    #expect(try await store.listDirectories().isEmpty)
    try await store.delete(instanceId: id)
    try await store.delete(instanceId: InstanceID.generate())
  }

  @Test func orphanCandidatesAreDirectoriesWithoutARow() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    var ids: [InstanceID] = []
    for _ in 0..<2 {
      let id = InstanceID.generate()
      _ = try await store.materialize(
        instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
        spec: SampleSpec(instanceId: id.rawValue)
      )
      ids.append(id)
    }
    #expect(try await store.orphanCandidates(known: Set(ids)).isEmpty)
    #expect(try await store.orphanCandidates(known: [ids[0]]) == [ids[1]])
    #expect(try await store.orphanCandidates(known: []).count == 2)
  }

  @Test func failureRecordRoundTrips() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let id = InstanceID.generate()
    _ = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    let record = FailureRecord(
      instanceId: id, error: VMError.bootTimeout(stage: "guest agent"), phase: "bootingVM",
      occurredAt: TempStore.createdAt, workerPID: 4242, details: ["serial_tail": "kernel panic"]
    )
    try await store.recordFailure(instanceId: id, record)
    let loaded = try #require(try await store.failureRecord(instanceId: id))
    #expect(loaded == record)
    #expect(loaded.code == "VM_BOOT_TIMEOUT")
    #expect(try env.mode(of: await store.layout(for: id).failure) == 0o600)
  }

  @Test func retentionSweepHonoursAge() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let store = env.instanceStore(now: { clock })

    var ids: [InstanceID] = []
    for _ in 0..<3 {
      let id = InstanceID.generate()
      _ = try await store.materialize(
        instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
        spec: SampleSpec(instanceId: id.rawValue)
      )
      ids.append(id)
    }
    let (old, recent, healthy) = (ids[0], ids[1], ids[2])
    try await store.recordFailure(
      instanceId: old,
      FailureRecord(instanceId: old, code: "VM_BOOT_TIMEOUT", message: "old",
                    occurredAt: clock.addingTimeInterval(-3 * 3600))
    )
    try await store.recordFailure(
      instanceId: recent,
      FailureRecord(instanceId: recent, code: "VM_BOOT_TIMEOUT", message: "recent",
                    occurredAt: clock.addingTimeInterval(-30 * 60))
    )

    let swept = try await store.retentionSweep(olderThan: .seconds(2 * 3600))
    #expect(swept == [old])
    #expect(!FileSystem.exists(env.paths.instanceDir(old)))
    #expect(FileSystem.exists(env.paths.instanceDir(recent)))
    // No failure.json: never touched here, that is the reconciler's business.
    #expect(FileSystem.exists(env.paths.instanceDir(healthy)))
  }

  @Test func sweepStagingDropsAbandonedAttempts() async throws {
    let env = try TempStore()
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let store = env.instanceStore(now: { clock.addingTimeInterval(7200) })
    let staging = env.paths.instancesDir.appending(path: ".tmp/dead", directoryHint: .isDirectory)
    try FileSystem.ensureDirectory(staging, permissions: 0o700)

    #expect(try await store.sweepStaging(olderThan: .seconds(3600)).count == 1)
    #expect(!FileSystem.exists(staging))
  }

  @Test func workerLockIsUnheldRightAfterMaterialization() async throws {
    let env = try TempStore()
    let image = try await importBase(env)
    let store = env.instanceStore()
    let id = InstanceID.generate()
    _ = try await store.materialize(
      instanceId: id, image: image.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )
    #expect(try await store.workerLockHolder(instanceId: id) == nil)
  }
}
