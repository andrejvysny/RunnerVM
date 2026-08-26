// Derived from openai/tart@16d186c Sources/tart/OCI/Layerizer/DiskV2.swift — FSL-1.1-ALv2.
// See PROVENANCE.md.
import Foundation
import RunnerCore

/// Turns a raw disk image into ordered LZ4 chunk layers and back again.
///
/// Both directions write only to caller-supplied paths. Verifying the result and publishing it
/// atomically is `ImageStore`'s job (spec §119, §120) — nothing here renames anything into place.
public enum DiskLayerizer {
  /// Decision D7: 512 MiB, matching what registries and their proxies handle comfortably.
  public static let defaultChunkBytes = 512 * 1024 * 1024
  public static let defaultConcurrency = 4

  public struct PushedDisk: Sendable, Equatable {
    public let chunks: [OCIDescriptor]
    public let virtualSize: UInt64
    /// sha256 of the whole raw disk, which is what a pull verifies against.
    public let contentDigest: String
  }

  /// Chunks, compresses and uploads `diskURL`.
  ///
  /// - Parameter staging: scratch directory for compressed chunks; each file is deleted as soon as
  ///   it has been uploaded, so peak usage is `concurrency` compressed chunks.
  public static func push(
    diskURL: URL, repository: String, registry: RegistryClient, staging: URL,
    chunkBytes: Int = DiskLayerizer.defaultChunkBytes, concurrency: Int = DiskLayerizer.defaultConcurrency,
    progress: TransferProgress? = nil
  ) async throws -> PushedDisk {
    let virtualSize = try fileSize(of: diskURL)
    guard virtualSize > 0, chunkBytes > 0 else {
      throw RegistryError.invalidResponse(operation: "push disk", reason: "empty disk image")
    }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    // A second sequential pass: the parallel chunk readers cannot produce one ordered hash.
    let contentDigest = try ContentDigest.hashFile(at: diskURL)
    let plan = chunkPlan(virtualSize: virtualSize, chunkBytes: chunkBytes)

    var descriptors: [(index: Int, descriptor: OCIDescriptor)] = []
    try await withThrowingTaskGroup(of: (Int, OCIDescriptor).self) { group in
      for (index, span) in plan.enumerated() {
        if index >= concurrency, let done = try await group.next() { descriptors.append(done) }
        group.addTask {
          let descriptor = try await pushChunk(
            diskURL: diskURL, index: index, span: span, staging: staging,
            repository: repository, registry: registry
          )
          progress?.advance(by: UInt64(span.length))
          return (index, descriptor)
        }
      }
      for try await done in group {
        descriptors.append(done)
      }
    }
    return PushedDisk(
      chunks: descriptors.sorted { $0.index < $1.index }.map(\.descriptor),
      virtualSize: virtualSize, contentDigest: contentDigest
    )
  }

  /// Reassembles `chunks` into `diskURL`, resuming an interrupted attempt and keeping the file
  /// sparse.
  public static func pull(
    chunks: [OCIDescriptor], to diskURL: URL, virtualSize: UInt64, contentDigest: String?,
    repository: String, registry: RegistryClient, concurrency: Int = DiskLayerizer.defaultConcurrency,
    progress: TransferProgress? = nil
  ) async throws {
    let resumed = FileManager.default.fileExists(atPath: diskURL.path(percentEncoded: false))
    if !resumed {
      guard FileManager.default.createFile(atPath: diskURL.path(percentEncoded: false), contents: nil)
      else {
        throw RegistryError.invalidResponse(operation: "pull disk", reason: "cannot create \(diskURL.path)")
      }
    }
    try truncate(diskURL, to: virtualSize)
    let layout = try layout(of: chunks, virtualSize: virtualSize)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, placed) in layout.enumerated() {
        if index >= concurrency { try await group.next() }
        group.addTask {
          try await pullChunk(
            placed: placed, to: diskURL, repository: repository, registry: registry, resumed: resumed
          )
          progress?.advance(by: UInt64(placed.descriptor.size))
        }
      }
      try await group.waitForAll()
    }

    guard let contentDigest else { return }
    let actual = try ContentDigest.hashFile(at: diskURL)
    guard actual == contentDigest else {
      throw RegistryError.digestMismatch(expected: contentDigest, actual: actual)
    }
  }

  // MARK: - One chunk

  struct ChunkSpan {
    let offset: UInt64
    let length: Int
  }

  struct PlacedChunk {
    let descriptor: OCIDescriptor
    let offset: UInt64
    let uncompressedSize: UInt64
    let uncompressedDigest: String
  }

  private static func pushChunk(
    diskURL: URL, index: Int, span: ChunkSpan, staging: URL, repository: String,
    registry: RegistryClient
  ) async throws -> OCIDescriptor {
    let compressedURL = staging.appending(path: "chunk-\(index).lz4")
    defer { try? FileManager.default.removeItem(at: compressedURL) }
    let chunk = try LZ4Codec.compressChunk(
      source: diskURL, offset: span.offset, length: span.length, to: compressedURL
    )
    if try await !registry.blobExists(chunk.compressedDigest, repository: repository) {
      let file = try FileHandle(forReadingFrom: compressedURL)
      defer { try? file.close() }
      try await registry.pushBlob(
        digest: chunk.compressedDigest, size: chunk.compressedSize, repository: repository
      ) { offset, length in
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: length) ?? Data()
      }
    }
    return OCIDescriptor(
      mediaType: RunnerVMMediaType.diskChunk, digest: chunk.compressedDigest,
      size: Int64(chunk.compressedSize),
      annotations: [
        RunnerVMAnnotation.chunkIndex: String(index),
        RunnerVMAnnotation.chunkUncompressedSize: String(chunk.uncompressedSize),
        RunnerVMAnnotation.chunkUncompressedDigest: chunk.uncompressedDigest,
      ]
    )
  }

  private static func pullChunk(
    placed: PlacedChunk, to diskURL: URL, repository: String, registry: RegistryClient, resumed: Bool
  ) async throws {
    if resumed, let onDisk = try? ContentDigest.hashFile(
      at: diskURL, offset: placed.offset, size: placed.uncompressedSize
    ), onDisk == placed.uncompressedDigest {
      return
    }
    let writer = try SparseDiskWriter(url: diskURL, startingAt: placed.offset, punchHoles: resumed)
    let decompressor = try LZ4Codec.Decompressor { data in try writer.write(data) }
    try await registry.pullBlob(
      placed.descriptor.digest, repository: repository, expectedSize: placed.descriptor.size
    ) { data in
      try decompressor.write(data)
    }
    try decompressor.finalize()
    try writer.close()
    let actual = try ContentDigest.hashFile(
      at: diskURL, offset: placed.offset, size: placed.uncompressedSize
    )
    guard actual == placed.uncompressedDigest else {
      throw RegistryError.digestMismatch(expected: placed.uncompressedDigest, actual: actual)
    }
  }

  // MARK: - Layout

  static func chunkPlan(virtualSize: UInt64, chunkBytes: Int) -> [ChunkSpan] {
    var spans: [ChunkSpan] = []
    var offset: UInt64 = 0
    while offset < virtualSize {
      let length = Int(min(UInt64(chunkBytes), virtualSize - offset))
      spans.append(ChunkSpan(offset: offset, length: length))
      offset += UInt64(length)
    }
    return spans
  }

  static func layout(of chunks: [OCIDescriptor], virtualSize: UInt64) throws -> [PlacedChunk] {
    var offset: UInt64 = 0
    var placed: [PlacedChunk] = []
    for chunk in chunks {
      let size = try chunk.requiredUInt64Annotation(RunnerVMAnnotation.chunkUncompressedSize)
      let digest = try chunk.requiredAnnotation(RunnerVMAnnotation.chunkUncompressedDigest)
      placed.append(
        PlacedChunk(descriptor: chunk, offset: offset, uncompressedSize: size, uncompressedDigest: digest)
      )
      offset += size
    }
    guard offset == virtualSize else {
      throw RegistryError.unsupportedManifest(
        reason: "chunks describe \(offset) bytes but the disk is \(virtualSize)"
      )
    }
    return placed
  }

  static func fileSize(of url: URL) throws -> UInt64 {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    return try file.seekToEnd()
  }

  private static func truncate(_ url: URL, to size: UInt64) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.truncate(atOffset: size)
  }
}
