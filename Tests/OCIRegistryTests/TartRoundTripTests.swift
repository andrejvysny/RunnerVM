import Compression
import Foundation
import ImageStore
@testable import OCIRegistry
import RunnerCore
import Testing

/// Spec §58 end to end against a `FakeRegistry` holding a real tart-shaped image: the manifest,
/// the two config blobs and LZ4 chunk layers tart itself would push.
struct TartRoundTripTests {
  private static let repository = "cirruslabs/ubuntu"
  private static let diskBytes: UInt64 = 64 << 20
  private static let chunkBytes = 8 << 20
  /// Same shape `DiskLayerizerTests` uses: three data islands with real holes between them, which
  /// APFS actually leaves unallocated at this size.
  private static let islands: [(offset: UInt64, bytes: Int)] = [
    (0, 512 << 10), (9 << 20, 1 << 20), (33 << 20, 256 << 10),
  ]
  /// The chunk holding the 33 MiB island, so a scripted failure lands on one with real content
  /// rather than on a run of zeros the resume check would skip anyway.
  private static let failingChunkIndex = 4

  private struct Fixture {
    let fake: FakeRegistry
    let client: RegistryClient
    let temp: TempDirectory
    let diskURL: URL
    let nvramURL: URL
    let published: TartImagePublisher.Published
  }

  private func makeFixture(_ label: String, uploadTime: Date? = nil) throws -> Fixture {
    let temp = try TempDirectory(label)
    let fake = FakeRegistry()
    let disk = try Fixtures.makeSparseDisk(
      at: temp.appending("disk.img"), virtualBytes: Self.diskBytes, islands: Self.islands
    )
    let nvram = temp.appending("nvram.bin")
    try Fixtures.pattern(seed: 7, count: 64 << 10).write(to: nvram)
    let published = try TartImagePublisher.publish(
      into: fake, diskURL: disk, nvramURL: nvram, staging: try temp.directory("publish"),
      repository: Self.repository, chunkBytes: Self.chunkBytes, uploadTime: uploadTime
    )
    return Fixture(
      fake: fake, client: fake.makeClient(), temp: temp, diskURL: disk, nvramURL: nvram,
      published: published
    )
  }

  private func blobGETs(_ fake: FakeRegistry) -> Int {
    fake.requests("GET", containing: "/blobs/").count
  }

  private func chunkGETs(_ fixture: Fixture) -> [String] {
    fixture.fake.requests("GET", containing: "/blobs/").compactMap { request in
      fixture.published.chunkDigests.first { request.path.hasSuffix($0) }
    }
  }

  // MARK: - Inspect

  @Test func inspectDetectsATartManifestWithoutAWholeDiskDigest() async throws {
    let fixture = try makeFixture("tart-inspect", uploadTime: Fixtures.createdAt)
    defer { fixture.fake.shutdown() }

    let remote = try await RunnerVMImageTransfer.inspect(
      fixture.published.reference, registry: fixture.client)

    #expect(remote.format == .tart)
    #expect(remote.digest == fixture.published.manifestDigest)
    #expect(remote.transferBytes > 0)
    #expect(remote.artifact.diskContentDigest == nil)
    #expect(remote.artifact.diskVirtualSize == Self.diskBytes)
    #expect(remote.artifact.nvram?.digest == fixture.published.nvramDigest)
    #expect(remote.metadata.os == .linux)
    #expect(remote.metadata.createdAt == Fixtures.createdAt)
    #expect(remote.metadata.hasGuestAgent == false)
    #expect(remote.metadata.provenance?.imported?.format == "tart")
    // Only the two config blobs; not one disk chunk.
    #expect(blobGETs(fixture.fake) == 2)
  }

  // MARK: - Pull

  @Test func pullReassemblesTheDiskByteForByteAndKeepsItSparse() async throws {
    let fixture = try makeFixture("tart-pull")
    defer { fixture.fake.shutdown() }

    let pulled = try await RunnerVMImageTransfer.pull(
      fixture.published.reference, registry: fixture.client,
      into: try fixture.temp.directory("staging"), concurrency: 2)

    #expect(try Fixtures.fileBytes(at: pulled.diskURL) == (try Fixtures.fileBytes(at: fixture.diskURL)))
    // Zero runs were skipped, so the reassembled file commits blocks only where the islands are;
    // the sparse writer works at 4 MiB granularity, so each island may cost one window.
    let allocated = try Fixtures.allocatedBytes(at: pulled.diskURL)
    #expect(allocated > 0)
    #expect(
      allocated <= UInt64(Self.islands.count + 1) * (4 << 20),
      "allocated=\(allocated) virtual=\(Self.diskBytes)")
    #expect(try Data(contentsOf: try #require(pulled.nvramURL)) == (try Data(contentsOf: fixture.nvramURL)))
    #expect(pulled.metadata.virtualDiskSizeBytes == Self.diskBytes)
  }

  @Test func resumingAPullRefetchesOnlyTheConfigBlobs() async throws {
    let fixture = try makeFixture("tart-resume")
    defer { fixture.fake.shutdown() }
    let staging = try fixture.temp.directory("staging")
    _ = try await RunnerVMImageTransfer.pull(
      fixture.published.reference, registry: fixture.client, into: staging, concurrency: 1)
    fixture.fake.resetRecording()

    let second = try await RunnerVMImageTransfer.pull(
      fixture.published.reference, registry: fixture.client, into: staging, concurrency: 1)

    #expect(try Fixtures.fileBytes(at: second.diskURL) == (try Fixtures.fileBytes(at: fixture.diskURL)))
    #expect(chunkGETs(fixture).isEmpty)
    // The OCI config, the tart config layer, and the NVRAM blob -- which is small, unchunked and
    // has nothing resumable about it. No disk chunk is fetched twice.
    #expect(blobGETs(fixture.fake) == 3)
  }

  @Test func resumingAfterAFailedChunkRefetchesOnlyThatChunk() async throws {
    let fixture = try makeFixture("tart-resume-chunk")
    defer { fixture.fake.shutdown() }
    let staging = try fixture.temp.directory("staging")
    let failing = fixture.published.chunkDigests[Self.failingChunkIndex]
    fixture.fake.failBlobGet(digest: failing, status: 500, times: 8)
    await #expect(throws: RegistryError.self) {
      _ = try await RunnerVMImageTransfer.pull(
        fixture.published.reference, registry: fixture.client, into: staging, concurrency: 1)
    }

    fixture.fake.clearBlobFaults()
    fixture.fake.resetRecording()
    let second = try await RunnerVMImageTransfer.pull(
      fixture.published.reference, registry: fixture.client, into: staging, concurrency: 1)

    #expect(try Fixtures.fileBytes(at: second.diskURL) == (try Fixtures.fileBytes(at: fixture.diskURL)))
    #expect(chunkGETs(fixture) == [failing])
  }

  /// There is no whole-disk digest in a flat tart manifest, so the per-chunk uncompressed digest
  /// is the only end-to-end check — and it has to be enough.
  @Test func aChunkThatDoesNotMatchItsAnnotatedDigestFailsThePull() async throws {
    let fixture = try makeFixture("tart-corrupt")
    defer { fixture.fake.shutdown() }
    let data = try #require(fixture.fake.manifestData(repository: Self.repository, reference: "latest"))
    var manifest = try OCIManifest.decode(data)
    manifest.layers[2].annotations?[TartAnnotation.uncompressedContentDigest] =
      "sha256:" + String(repeating: "0", count: 64)
    fixture.fake.putManifest(
      try manifest.encoded(), repository: Self.repository, reference: "lying")

    let error = await #expect(throws: RegistryError.self) {
      _ = try await RunnerVMImageTransfer.pull(
        try fixture.fake.reference(Self.repository, tag: "lying"), registry: fixture.client,
        into: try fixture.temp.directory("staging"), concurrency: 1)
    }

    #expect(error?.code == "REGISTRY_DIGEST_MISMATCH")
  }

  @Test func theConvertedMetadataIsAcceptedByTheLocalImageStore() async throws {
    let fixture = try makeFixture("tart-import")
    defer { fixture.fake.shutdown() }
    let root = try fixture.temp.directory("store")
    let store = ImageStore(
      paths: RunnerPaths(
        rootDir: root, runtimeDir: root.appending(path: "run", directoryHint: .isDirectory)))

    let pulled = try await RunnerVMImageTransfer.pull(
      fixture.published.reference, registry: fixture.client,
      into: try fixture.temp.directory("staging"), concurrency: 2)
    let imported = try await store.importLocal(
      disk: pulled.diskURL, nvram: pulled.nvramURL, metadata: pulled.metadata,
      name: fixture.published.reference.description)

    let info = try await store.inspect(digest: imported.digest)
    #expect(info.metadata.hasGuestAgent == false)
    #expect(info.metadata.provenance?.imported?.format == "tart")
    #expect(
      info.metadata.provenance?.imported?.manifestDigest
        == fixture.published.manifestDigest.rawValue)
    #expect(info.metadata.virtualDiskSizeBytes == Self.diskBytes)
  }

  // MARK: - Format and purpose gates

  @Test func aForcedFormatRefusesTheOtherSchemaBeforeAnyBlobIsFetched() async throws {
    let fixture = try makeFixture("tart-format")
    defer { fixture.fake.shutdown() }
    let runnerVM = try await publishRunnerVM(fixture)
    fixture.fake.resetRecording()

    let wrongTart = await #expect(throws: RegistryError.self) {
      _ = try await RunnerVMImageTransfer.inspect(
        fixture.published.reference, registry: fixture.client, require: .runnervm)
    }
    #expect(wrongTart?.message.contains("manifest is tart, not runnervm") == true)

    let wrongRunnerVM = await #expect(throws: RegistryError.self) {
      _ = try await RunnerVMImageTransfer.inspect(runnerVM, registry: fixture.client, require: .tart)
    }
    #expect(wrongRunnerVM?.message.contains("manifest is runnervm, not tart") == true)
    #expect(blobGETs(fixture.fake) == 0)
  }

  @Test func aPullForAnInstanceIsRefusedAfterTheConfigBlobsAndBeforeAnyChunk() async throws {
    let fixture = try makeFixture("tart-purpose")
    defer { fixture.fake.shutdown() }
    fixture.fake.resetRecording()

    let error = await #expect(throws: ImageError.self) {
      _ = try await RunnerVMImageTransfer.inspect(
        fixture.published.reference, registry: fixture.client, purpose: .instance)
    }

    #expect(error?.code == "IMAGE_NO_GUEST_AGENT")
    #expect(chunkGETs(fixture).isEmpty)
    #expect(blobGETs(fixture.fake) == 2)
  }

  @Test func storagePurposeStillAcceptsAnAgentlessImage() async throws {
    let fixture = try makeFixture("tart-storage")
    defer { fixture.fake.shutdown() }

    let remote = try await RunnerVMImageTransfer.inspect(
      fixture.published.reference, registry: fixture.client, require: .tart, purpose: .storage)

    #expect(remote.format == .tart)
  }

  // MARK: - Compression compatibility

  /// tart pushes each chunk with the one-shot `(data as NSData).compressed(using: .lz4)`; this
  /// project reads it with `Compression`'s streaming filter. The two have to agree, or every
  /// imported image would decode to garbage.
  @Test func tartsOneShotLZ4OutputDecompressesThroughTheStreamingDecompressor() throws {
    let plain = Fixtures.pattern(seed: 5, count: 1 << 20)
    let compressed = try (plain as NSData).compressed(using: .lz4) as Data
    let sink = DataSink()

    let decompressor = try LZ4Codec.Decompressor(sink: { sink.append($0) })
    // Fed in pieces, the way a streamed blob body arrives.
    for slice in stride(from: 0, to: compressed.count, by: 64 << 10) {
      let end = min(slice + (64 << 10), compressed.count)
      try decompressor.write(compressed.subdata(in: slice ..< end))
    }
    try decompressor.finalize()

    #expect(sink.data == plain)
  }

  // MARK: - Helpers

  /// A RunnerVM-format image in the same registry, so the `require:` gate has both schemas to
  /// choose between.
  private func publishRunnerVM(_ fixture: Fixture) async throws -> OCIReference {
    let reference = try fixture.fake.reference("acme/runnervm/ubuntu", tag: "stable")
    _ = try await RunnerVMImageTransfer.push(
      diskURL: fixture.diskURL, nvramURL: nil,
      metadata: Fixtures.linuxMetadata(virtualDiskSizeBytes: Self.diskBytes), to: reference,
      registry: fixture.client, staging: try fixture.temp.directory("runnervm-push"),
      chunkBytes: Self.chunkBytes, concurrency: 2)
    return reference
  }
}

/// Collects a streaming decompressor's output. A class rather than a captured `var` so the
/// escaping sink closure has somewhere unambiguous to write.
private final class DataSink: @unchecked Sendable {
  private(set) var data = Data()

  func append(_ chunk: Data) {
    data.append(chunk)
  }
}
