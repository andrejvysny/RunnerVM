import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

struct DiskLayerizerTests {
  private static let repository = "acme/runnervm/ubuntu-24"
  private static let virtualBytes: UInt64 = 64 * 1024 * 1024
  private static let chunkBytes = 8 * 1024 * 1024
  /// Islands of real data separated by holes, the shape of a real runner image.
  private static let islands: [(offset: UInt64, bytes: Int)] = [
    (0, 512 * 1024),
    (9 * 1024 * 1024, 1024 * 1024),
    (33 * 1024 * 1024, 256 * 1024),
  ]

  private func makeDisk(_ temp: TempDirectory) throws -> URL {
    try Fixtures.makeSparseDisk(
      at: temp.appending("source.img"), virtualBytes: Self.virtualBytes, islands: Self.islands
    )
  }

  @Test func chunkPlanCoversTheDiskExactly() {
    let plan = DiskLayerizer.chunkPlan(virtualSize: 20, chunkBytes: 8)
    #expect(plan.map(\.length) == [8, 8, 4])
    #expect(plan.map(\.offset) == [0, 8, 16])
  }

  @Test func roundTripsADiskByteForByteAndKeepsItSparse() async throws {
    let temp = try TempDirectory("layerizer-roundtrip")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let source = try makeDisk(temp)

    let pushed = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: client,
      staging: temp.directory("push"), chunkBytes: Self.chunkBytes, concurrency: 2
    )
    #expect(pushed.chunks.count == 8)
    #expect(pushed.virtualSize == Self.virtualBytes)
    #expect(try pushed.contentDigest == (ContentDigest.hashFile(at: source)))
    // The staging directory is emptied as each chunk is uploaded.
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.appending("push").path).isEmpty)

    let destination = try temp.directory("pull").appending(path: "disk.img.partial")
    try await DiskLayerizer.pull(
      chunks: pushed.chunks, to: destination, virtualSize: pushed.virtualSize,
      contentDigest: pushed.contentDigest, repository: Self.repository, registry: client, concurrency: 2
    )

    #expect(try Fixtures.fileBytes(at: destination) == (Fixtures.fileBytes(at: source)))
    // Zero runs were skipped, so the reassembled file commits blocks only where the islands are.
    let allocated = try Fixtures.allocatedBytes(at: destination)
    #expect(allocated < Self.virtualBytes / 2)
    // The sparse writer skips zeros at 4 MiB granularity (tart-proven trade-off), so each data
    // island may commit up to one 4 MiB window; anything beyond that is a reassembly regression.
    let holeGranularity: UInt64 = 4 << 20
    let worstCase = UInt64(Self.islands.count) * holeGranularity + holeGranularity
    #expect(allocated <= worstCase, "allocated=\(allocated) worstCase=\(worstCase) virtual=\(Self.virtualBytes)")
    #expect(allocated > 0)
  }

  @Test func compressedLayersAreSmallerThanTheDisk() async throws {
    let temp = try TempDirectory("layerizer-compression")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let source = try makeDisk(temp)
    let pushed = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: fake.makeClient(),
      staging: temp.directory("push"), chunkBytes: Self.chunkBytes, concurrency: 1
    )
    let compressed = pushed.chunks.reduce(Int64(0)) { $0 + $1.size }
    #expect(compressed < Int64(Self.virtualBytes) / 4)
    #expect(pushed.chunks.allSatisfy { $0.mediaType == RunnerVMMediaType.diskChunk })
    #expect(
      pushed.chunks.enumerated()
        .allSatisfy { $1.annotation(RunnerVMAnnotation.chunkIndex) == String($0) }
    )
  }

  @Test func pushSkipsBlobsTheRegistryAlreadyHas() async throws {
    let temp = try TempDirectory("layerizer-dedup")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let source = try makeDisk(temp)

    let first = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: client,
      staging: temp.directory("push1"), chunkBytes: Self.chunkBytes, concurrency: 1
    )
    fake.resetRecording()
    let second = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: client,
      staging: temp.directory("push2"), chunkBytes: Self.chunkBytes, concurrency: 1
    )

    #expect(first.chunks == second.chunks)
    #expect(fake.requests("POST", containing: "/blobs/uploads/").isEmpty)
    #expect(fake.requests("HEAD", containing: "/blobs/").count == 8)
  }

  @Test func resumedPullSkipsChunksAlreadyOnDisk() async throws {
    let temp = try TempDirectory("layerizer-resume")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient(options: RegistryClient.Options(retryPolicy: RetryPolicy(maxAttempts: 2)))
    let source = try makeDisk(temp)
    let pushed = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: client,
      staging: temp.directory("push"), chunkBytes: Self.chunkBytes, concurrency: 1
    )
    let destination = try temp.directory("pull").appending(path: "disk.img.partial")

    // Chunk 0 lands, chunk 1 exhausts its retries: the pull dies with a partial file behind it.
    fake.failBlobGet(digest: pushed.chunks[1].digest, status: 500, times: 2)
    await #expect(throws: RegistryError.self) {
      try await DiskLayerizer.pull(
        chunks: pushed.chunks, to: destination, virtualSize: pushed.virtualSize,
        contentDigest: pushed.contentDigest, repository: Self.repository, registry: client,
        concurrency: 1
      )
    }
    #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))

    fake.clearBlobFaults()
    fake.resetRecording()
    try await DiskLayerizer.pull(
      chunks: pushed.chunks, to: destination, virtualSize: pushed.virtualSize,
      contentDigest: pushed.contentDigest, repository: Self.repository, registry: client, concurrency: 1
    )

    #expect(try Fixtures.fileBytes(at: destination) == (Fixtures.fileBytes(at: source)))
    // Only the chunk that failed and the one other chunk carrying data are refetched: every
    // all-zero chunk already matches the pre-truncated file and verifies in place.
    let refetched = fake.requests("GET", containing: "/blobs/")
    #expect(refetched.allSatisfy { !$0.path.contains(pushed.chunks[0].digest) })
    #expect(refetched.count == 2)
    #expect(refetched.contains { $0.path.contains(pushed.chunks[1].digest) })
  }

  @Test func corruptedChunkFailsThePull() async throws {
    let temp = try TempDirectory("layerizer-corrupt")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let source = try makeDisk(temp)
    let pushed = try await DiskLayerizer.push(
      diskURL: source, repository: Self.repository, registry: client,
      staging: temp.directory("push"), chunkBytes: Self.chunkBytes, concurrency: 1
    )
    // The registry serves a different (still valid) LZ4 stream under this chunk's digest.
    let impostor = try #require(fake.blob(pushed.chunks[0].digest))
    fake.overwriteBlob(pushed.chunks[2].digest, with: impostor)

    do {
      try await DiskLayerizer.pull(
        chunks: pushed.chunks, to: temp.directory("pull").appending(path: "disk.img.partial"),
        virtualSize: pushed.virtualSize, contentDigest: pushed.contentDigest,
        repository: Self.repository, registry: client, concurrency: 1
      )
      Issue.record("expected the corrupted chunk to be rejected")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_DIGEST_MISMATCH")
    }
  }

  @Test func nvramLayerRoundTrips() async throws {
    let temp = try TempDirectory("nvram")
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let source = temp.appending("nvram.bin")
    let payload = Fixtures.pattern(seed: 42, count: 64 * 1024)
    try payload.write(to: source)

    let descriptor = try await NVRAMLayer.push(
      fileURL: source, os: .linux, repository: Self.repository, registry: client
    )
    #expect(descriptor.mediaType == RunnerVMMediaType.efi)

    let destination = temp.appending("nvram.out")
    try await NVRAMLayer.pull(
      descriptor: descriptor, to: destination, repository: Self.repository, registry: client
    )
    #expect(try Data(contentsOf: destination) == payload)
  }
}
