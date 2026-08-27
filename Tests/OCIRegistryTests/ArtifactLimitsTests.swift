import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

/// A registry is not a trusted party the moment a manifest can come from anywhere but this host's
/// own push: every case here is a manifest crafted to lie about a size or a digest, and every one
/// of them must be rejected by `inspect` before a single disk-chunk blob is ever fetched -- a pull
/// has not even started at that point.
struct ArtifactLimitsTests {
  private static let repository = "acme/runnervm/artifact-limits"
  private static let limits = ArtifactLimits.default

  private static func chunk(
    index: Int, size: UInt64, seed: Character, descriptorSize: Int64? = nil,
    digest: String? = nil
  ) -> OCIDescriptor {
    OCIDescriptor(
      mediaType: RunnerVMMediaType.diskChunk,
      digest: digest ?? "sha256:" + String(repeating: seed, count: 64),
      size: descriptorSize ?? Int64(size / 2),
      annotations: [
        RunnerVMAnnotation.chunkIndex: String(index),
        RunnerVMAnnotation.chunkUncompressedSize: String(size),
        RunnerVMAnnotation.chunkUncompressedDigest: "sha256:" + String(repeating: "9", count: 64),
      ]
    )
  }

  private static func manifest(
    config: OCIDescriptor, chunks: [OCIDescriptor], nvram: OCIDescriptor? = nil,
    virtualSize: UInt64
  ) -> OCIManifest {
    RunnerVMArtifact.makeManifest(
      config: config, diskChunks: chunks, nvram: nvram, diskVirtualSize: virtualSize,
      diskContentDigest: "sha256:" + String(repeating: "f", count: 64), createdAt: Fixtures.createdAt
    )
  }

  /// Publishes `manifest` (with `configBlob` behind `manifest.config.digest`) and asserts `inspect`
  /// rejects it without ever fetching a disk-chunk or NVRAM blob.
  private func expectRejected(
    _ manifest: OCIManifest, configBlob: Data, chunkDigests: [String]
  ) async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    fake.putBlob(configBlob)
    let reference = try fake.reference(Self.repository)
    fake.putManifest(
      try manifest.encoded(), repository: Self.repository, reference: reference.manifestReference
    )
    await #expect(throws: RegistryError.self) {
      _ = try await RunnerVMImageTransfer.inspect(reference, registry: client)
    }
    let layerFetches = fake.requests("GET", containing: "/blobs/")
    for digest in chunkDigests {
      #expect(layerFetches.allSatisfy { !$0.path.contains(digest) })
    }
  }

  @Test func negativeDescriptorSizeIsRejected() async throws {
    let configBlob = Data("not-a-real-config".utf8)
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let badChunk = Self.chunk(index: 0, size: 1024, seed: "a", descriptorSize: -1)
    let manifest = Self.manifest(config: config, chunks: [badChunk], virtualSize: 1024)
    try await expectRejected(manifest, configBlob: configBlob, chunkDigests: [badChunk.digest])
  }

  @Test func malformedDigestGrammarIsRejected() async throws {
    let configBlob = Data("not-a-real-config".utf8)
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let badChunk = Self.chunk(
      index: 0, size: 1024, seed: "a", digest: "sha256:not-hex-and-too-short"
    )
    let manifest = Self.manifest(config: config, chunks: [badChunk], virtualSize: 1024)
    try await expectRejected(manifest, configBlob: configBlob, chunkDigests: [badChunk.digest])
  }

  @Test func tooManyLayersIsRejected() async throws {
    let configBlob = Data("not-a-real-config".utf8)
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let chunks = (0...Self.limits.maxLayers).map { Self.chunk(index: $0, size: 1, seed: "a") }
    let manifest = Self.manifest(config: config, chunks: chunks, virtualSize: UInt64(chunks.count))
    try await expectRejected(manifest, configBlob: configBlob, chunkDigests: [chunks[0].digest])
  }

  @Test func oversizedConfigIsRejectedEvenWhenTheActualBlobIsSmall() async throws {
    // A small, real blob behind the digest -- only the manifest's *declared* size lies.
    let configBlob = Data("not-a-real-config".utf8)
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Self.limits.maxConfigBytes + 1
    )
    let goodChunk = Self.chunk(index: 0, size: 1024, seed: "a")
    let manifest = Self.manifest(config: config, chunks: [goodChunk], virtualSize: 1024)
    try await expectRejected(manifest, configBlob: configBlob, chunkDigests: [goodChunk.digest])
  }

  @Test func oversizedVirtualDiskIsRejected() async throws {
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: 4096)
    let configBlob = try RunnerVMConfig(metadata: metadata).encoded()
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let hugeSize = Self.limits.maxVirtualDiskBytes + (1 << 30)
    let chunk = Self.chunk(index: 0, size: hugeSize, seed: "a")
    let manifest = Self.manifest(config: config, chunks: [chunk], virtualSize: hugeSize)
    try await expectRejected(manifest, configBlob: configBlob, chunkDigests: [chunk.digest])
  }

  @Test func oversizedNVRAMIsRejected() async throws {
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: 4096)
    let configBlob = try RunnerVMConfig(metadata: metadata).encoded()
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let chunk = Self.chunk(index: 0, size: 4096, seed: "a")
    let nvram = OCIDescriptor(
      mediaType: RunnerVMMediaType.efi, digest: "sha256:" + String(repeating: "e", count: 64),
      size: Self.limits.maxNVRAMBytes + 1
    )
    let manifest = Self.manifest(config: config, chunks: [chunk], nvram: nvram, virtualSize: 4096)
    try await expectRejected(
      manifest, configBlob: configBlob, chunkDigests: [chunk.digest, nvram.digest]
    )
  }

  @Test func negativeNVRAMSizeIsRejected() async throws {
    let configBlob = Data("not-a-real-config".utf8)
    let config = OCIDescriptor(
      mediaType: RunnerVMMediaType.config, digest: ContentDigest.hash(configBlob),
      size: Int64(configBlob.count)
    )
    let chunk = Self.chunk(index: 0, size: 4096, seed: "a")
    let nvram = OCIDescriptor(
      mediaType: RunnerVMMediaType.efi, digest: "sha256:" + String(repeating: "e", count: 64), size: -1
    )
    let manifest = Self.manifest(config: config, chunks: [chunk], nvram: nvram, virtualSize: 4096)
    try await expectRejected(
      manifest, configBlob: configBlob, chunkDigests: [chunk.digest, nvram.digest]
    )
  }

  // MARK: - Bounded decompression

  /// An LZ4 stream is not obligated to tell the truth about how large it decompresses to; the
  /// declared uncompressed size on the chunk annotation is the only budget the pull has to go on.
  @Test func decompressorRejectsAStreamThatExpandsBeyondItsDeclaredSize() throws {
    let temp = try TempDirectory("lz4-declared-size")
    let source = temp.appending("zeros.bin")
    let zeros = Data(count: 2 * 1024 * 1024)
    try zeros.write(to: source)
    let compressed = temp.appending("zeros.lz4")
    let chunk = try LZ4Codec.compressChunk(
      source: source, offset: 0, length: zeros.count, to: compressed
    )
    #expect(chunk.uncompressedSize == zeros.count)

    let compressedBytes = try Data(contentsOf: compressed)
    let declaredLimit = 1 * 1024 * 1024
    var received = Data()
    let decompressor = try LZ4Codec.Decompressor(
      sink: { data in received.append(data) }, limit: declaredLimit
    )
    #expect(throws: RegistryError.self) {
      try decompressor.write(compressedBytes)
      try decompressor.finalize()
    }
  }

  @Test func decompressorAllowsAStreamThatStaysWithinItsDeclaredSize() throws {
    let temp = try TempDirectory("lz4-declared-size-ok")
    let source = temp.appending("zeros.bin")
    let zeros = Data(count: 1 * 1024 * 1024)
    try zeros.write(to: source)
    let compressed = temp.appending("zeros.lz4")
    _ = try LZ4Codec.compressChunk(source: source, offset: 0, length: zeros.count, to: compressed)

    let compressedBytes = try Data(contentsOf: compressed)
    var received = Data()
    let decompressor = try LZ4Codec.Decompressor(
      sink: { data in received.append(data) }, limit: zeros.count
    )
    try decompressor.write(compressedBytes)
    try decompressor.finalize()
    #expect(received == zeros)
  }
}
