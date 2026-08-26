import Foundation
import RunnerCore
import Testing
@testable import ImageStore

@Suite struct CloneAndAccountingTests {
  @Test func temporaryDirectoryIsCloneCapable() throws {
    // Every supported host runs APFS; if this fails the whole CoW instance model is off the table.
    #expect(APFSClone.volumeSupportsClone(at: FileManager.default.temporaryDirectory))
    #expect(APFSClone.freeSpace(at: FileManager.default.temporaryDirectory) > 0)
  }

  @Test func volumeQueriesToleratePathsThatDoNotExistYet() throws {
    let missing = FileManager.default.temporaryDirectory
      .appending(path: "does-not-exist-\(UUID().uuidString)/images/blobs", directoryHint: .isDirectory)
    #expect(APFSClone.volumeSupportsClone(at: missing))
    #expect(APFSClone.freeSpace(at: missing) > 0)
  }

  @Test func cloneSharesBlocksAndFailsOnAnExistingDestination() throws {
    let env = try TempStore()
    let source = try env.makeSparseDisk(named: "source.img")
    let destination = env.root.appending(path: "clone.img")

    #expect(try APFSClone.clone(from: source, to: destination) == .apfsCoW)
    #expect(try FileSystem.fileSize(at: destination) == TempStore.diskBytes)
    #expect(FileSystem.allocatedBytes(at: destination) < 1 << 20)
    #expect(throws: ImageError.self) { try APFSClone.clone(from: source, to: destination) }
  }

  @Test func cloneReportsAMissingSource() throws {
    let env = try TempStore()
    #expect(throws: ImageError.self) {
      try APFSClone.clone(from: env.root.appending(path: "nope"), to: env.root.appending(path: "out"))
    }
  }

  @Test func reservationIsWorstCase() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let image = try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
    let info = try await env.images.inspect(digest: image.digest)

    #expect(DiskAccounting.estimatedAdditionalAllocation(for: 0, image: info) == TempStore.diskBytes)
    #expect(
      DiskAccounting.estimatedAdditionalAllocation(for: TempStore.diskBytes * 4, image: info)
        == TempStore.diskBytes * 4
    )
  }

  @Test func freeSpaceCheckRejectsImpossibleDemand() throws {
    let env = try TempStore()
    try DiskAccounting.hostFreeSpaceCheck(paths: env.paths, reserveBytes: 0, needed: 1 << 20)
    #expect(throws: ImageError.self) {
      try DiskAccounting.hostFreeSpaceCheck(paths: env.paths, reserveBytes: 0, needed: UInt64.max / 2)
    }
    // The floor is subtracted before the comparison, so a huge reserve starves any request.
    #expect(throws: ImageError.self) {
      try DiskAccounting.hostFreeSpaceCheck(paths: env.paths, reserveBytes: UInt64.max / 2, needed: 1)
    }
  }

  @Test func digestIdentityIgnoresNameAndLayerOrder() throws {
    let layers = [
      LocalImageManifest.Layer(
        role: .nvram, digest: "sha256:" + String(repeating: "1", count: 64), sizeBytes: 4096
      ),
      LocalImageManifest.Layer(
        role: .disk, digest: "sha256:" + String(repeating: "2", count: 64), sizeBytes: 100
      ),
    ]
    let forward = try LocalImageManifest.computeDigest(
      os: .linux, layers: layers, metadataDigest: "sha256:" + String(repeating: "3", count: 64)
    )
    let reversed = try LocalImageManifest.computeDigest(
      os: .linux, layers: layers.reversed(), metadataDigest: "sha256:" + String(repeating: "3", count: 64)
    )
    #expect(forward == reversed)
    #expect(forward.sha256Hex?.count == 64)

    let otherOS = try LocalImageManifest.computeDigest(
      os: .macos, layers: layers, metadataDigest: "sha256:" + String(repeating: "3", count: 64)
    )
    #expect(forward != otherOS)
  }
}
