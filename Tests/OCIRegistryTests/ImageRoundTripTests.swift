import Foundation
import ImageStore
@testable import OCIRegistry
import RunnerCore
import Testing

/// Spec P9: an image imported locally, pushed and pulled back must be the same image. The local
/// identity (`ImageDigest`) is computed from content only, so a round trip through a registry must
/// not change it.
struct ImageRoundTripTests {
  private static let repository = "acme/runnervm/ubuntu-24"
  private static let diskBytes: UInt64 = 32 * 1024 * 1024

  private struct Local {
    let paths: RunnerPaths
    let store: ImageStore
  }

  private func makeStore(_ temp: TempDirectory, _ name: String) throws -> Local {
    let root = try temp.directory(name)
    let paths = RunnerPaths(
      rootDir: root, runtimeDir: root.appending(path: "run", directoryHint: .isDirectory)
    )
    return Local(paths: paths, store: ImageStore(paths: paths))
  }

  @Test func imageSurvivesAPushAndPullWithTheSameIdentity() async throws {
    let temp = try TempDirectory("roundtrip")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let origin = try makeStore(temp, "origin")

    let disk = try Fixtures.makeSparseDisk(
      at: temp.appending("disk.img"), virtualBytes: Self.diskBytes,
      islands: [(0, 256 * 1024), (17 * 1024 * 1024, 512 * 1024)]
    )
    let nvram = temp.appending("nvram.bin")
    try Fixtures.pattern(seed: 8, count: 64 * 1024).write(to: nvram)
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: Self.diskBytes)

    let imported = try await origin.store.importLocal(disk: disk, nvram: nvram, metadata: metadata)
    let reference = try fake.reference(Self.repository, tag: "stable")

    let pushed = try await RunnerVMImageTransfer.push(
      diskURL: origin.store.blobURL(role: .disk, digest: imported.digest),
      nvramURL: origin.store.blobURL(role: .nvram, digest: imported.digest),
      metadata: metadata, to: reference, registry: client, staging: temp.directory("push"),
      chunkBytes: 8 * 1024 * 1024, concurrency: 2
    )
    #expect(pushed.reference.digest == pushed.manifestDigest)
    #expect(pushed.reference.tag == nil)
    #expect(pushed.manifest.artifactType == RunnerVMMediaType.artifact)
    #expect(pushed.manifest.layers.count == 5)

    let remote = try await RunnerVMImageTransfer.inspect(reference, registry: client)
    #expect(remote.digest == pushed.manifestDigest)
    #expect(remote.metadata == metadata)
    #expect(remote.transferBytes > 0)

    let pulled = try await RunnerVMImageTransfer.pull(
      reference, registry: client, into: temp.directory("staging"), concurrency: 2
    )
    #expect(pulled.metadata == metadata)
    #expect(pulled.diskURL.lastPathComponent == "disk.img.partial")
    #expect(try Fixtures.fileBytes(at: pulled.diskURL) == (Fixtures.fileBytes(at: disk)))

    let mirror = try makeStore(temp, "mirror")
    let reimported = try await mirror.store.importLocal(
      disk: pulled.diskURL, nvram: pulled.nvramURL, metadata: pulled.metadata
    )
    #expect(reimported.digest == imported.digest)
    #expect(reimported.manifest.layers == imported.manifest.layers)
  }

  @Test func resumingAPullIntoTheSameStagingDirectoryRefetchesNothing() async throws {
    let temp = try TempDirectory("roundtrip-resume")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()

    let disk = try Fixtures.makeSparseDisk(
      at: temp.appending("disk.img"), virtualBytes: Self.diskBytes,
      islands: [(0, 256 * 1024), (17 * 1024 * 1024, 512 * 1024)]
    )
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: Self.diskBytes)
    let reference = try fake.reference(Self.repository, tag: "stable")
    _ = try await RunnerVMImageTransfer.push(
      diskURL: disk, nvramURL: nil, metadata: metadata, to: reference, registry: client,
      staging: temp.directory("push"), chunkBytes: 8 * 1024 * 1024, concurrency: 1
    )

    let staging = try temp.directory("staging")
    _ = try await RunnerVMImageTransfer.pull(reference, registry: client, into: staging, concurrency: 1)
    fake.resetRecording()
    let second = try await RunnerVMImageTransfer.pull(
      reference, registry: client, into: staging, concurrency: 1
    )

    #expect(try Fixtures.fileBytes(at: second.diskURL) == (Fixtures.fileBytes(at: disk)))
    #expect(fake.requests("GET", containing: "/blobs/sha256:").count == 1) // the config blob only
  }

  @Test func pushRejectsMetadataThatContradictsTheDisk() async throws {
    let temp = try TempDirectory("roundtrip-mismatch")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let disk = try Fixtures.makeSparseDisk(
      at: temp.appending("disk.img"), virtualBytes: Self.diskBytes, islands: [(0, 4096)]
    )
    await #expect(throws: ImageError.self) {
      _ = try await RunnerVMImageTransfer.push(
        diskURL: disk, nvramURL: nil,
        metadata: Fixtures.linuxMetadata(virtualDiskSizeBytes: Self.diskBytes + 1),
        to: fake.reference(Self.repository), registry: fake.makeClient(),
        staging: temp.directory("push"), chunkBytes: 8 * 1024 * 1024
      )
    }
  }
}
