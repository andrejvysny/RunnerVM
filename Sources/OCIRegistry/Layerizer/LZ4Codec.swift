// Derived from openai/tart@16d186c Sources/tart/OCI/Layerizer/DiskV2.swift (Apple `Compression`
// LZ4 streaming idiom) — FSL-1.1-ALv2. See PROVENANCE.md.
import Compression
import Foundation

/// LZ4 through Apple's `Compression` framework (decision D7 — the framework has no zstd, and an
/// extra C dependency is not worth the ratio on disks that are mostly holes).
///
/// Every chunk is an independent stream, so a pull can start at any chunk and a resumed pull never
/// has to replay earlier ones.
enum LZ4Codec {
  static let bufferBytes = 4 * 1024 * 1024

  struct CompressedChunk {
    let compressedSize: Int
    let compressedDigest: String
    let uncompressedSize: Int
    let uncompressedDigest: String
  }

  /// Compresses `length` bytes of `source` starting at `offset` into `destination`, hashing both
  /// sides on the way through. Peak memory is one buffer, not one chunk.
  static func compressChunk(
    source: URL, offset: UInt64, length: Int, to destination: URL
  ) throws -> CompressedChunk {
    guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
    else {
      throw RegistryError.invalidResponse(
        operation: "compress chunk", reason: "cannot create \(destination.lastPathComponent)"
      )
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    try input.seek(toOffset: offset)

    var compressed = ContentDigest.Streaming()
    var uncompressed = ContentDigest.Streaming()
    var compressedSize = 0
    let filter = try OutputFilter(.compress, using: .lz4, bufferCapacity: bufferBytes) { data in
      guard let data, !data.isEmpty else { return }
      compressed.update(data)
      compressedSize += data.count
      try output.write(contentsOf: data)
    }

    var remaining = length
    while remaining > 0 {
      let piece: Data? = try autoreleasepool { try input.read(upToCount: min(bufferBytes, remaining)) }
      guard let piece, !piece.isEmpty else { break }
      uncompressed.update(piece)
      try filter.write(piece)
      remaining -= piece.count
    }
    try filter.finalize()
    try output.synchronize()
    return CompressedChunk(
      compressedSize: compressedSize, compressedDigest: compressed.finalize(),
      uncompressedSize: length - remaining, uncompressedDigest: uncompressed.finalize()
    )
  }

  /// Streaming decompressor: compressed bytes in, plain bytes out to `sink`.
  struct Decompressor {
    private let filter: OutputFilter

    init(sink: @escaping (Data) throws -> Void) throws {
      filter = try OutputFilter(.decompress, using: .lz4, bufferCapacity: LZ4Codec.bufferBytes) { data in
        guard let data, !data.isEmpty else { return }
        try sink(data)
      }
    }

    func write(_ data: Data) throws {
      try filter.write(data)
    }

    func finalize() throws {
      try filter.finalize()
    }
  }
}
