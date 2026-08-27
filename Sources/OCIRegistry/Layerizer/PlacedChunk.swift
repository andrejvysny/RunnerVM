// Derived from openai/tart@16d186c Sources/tart/OCI/Layerizer/DiskV2.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore

/// The two annotation keys `PlacedChunk.layout` reads off each descriptor. RunnerVM's own chunk
/// layers use `RunnerVMAnnotation`'s; a struct instead of a bare pair of strings keeps a future
/// second producer from having to fork `layout` itself just to change which keys it reads.
public struct ChunkAnnotationKeys: Sendable, Equatable {
  public let uncompressedSize: String
  public let uncompressedDigest: String

  public init(uncompressedSize: String, uncompressedDigest: String) {
    self.uncompressedSize = uncompressedSize
    self.uncompressedDigest = uncompressedDigest
  }

  public static let runnerVM = ChunkAnnotationKeys(
    uncompressedSize: RunnerVMAnnotation.chunkUncompressedSize,
    uncompressedDigest: RunnerVMAnnotation.chunkUncompressedDigest
  )
}

/// One disk chunk descriptor resolved to where its decompressed bytes land in the reassembled
/// file. Shared by push verification, pull placement and `RunnerVMArtifact.parse`'s size check, so
/// there is exactly one place that turns "ordered chunk annotations" into byte offsets.
public struct PlacedChunk: Sendable, Equatable {
  public let descriptor: OCIDescriptor
  public let offset: UInt64
  public let uncompressedSize: UInt64
  public let uncompressedDigest: String

  public init(
    descriptor: OCIDescriptor, offset: UInt64, uncompressedSize: UInt64, uncompressedDigest: String
  ) {
    self.descriptor = descriptor
    self.offset = offset
    self.uncompressedSize = uncompressedSize
    self.uncompressedDigest = uncompressedDigest
  }

  /// Walks `chunks` in order, accumulating each one's declared uncompressed size into an offset.
  ///
  /// `virtualSize` is `nil` when the chunks are the only source of truth for the disk's length (a
  /// push, computing what it just wrote); non-nil cross-checks it (a pull, or a manifest parse,
  /// where the manifest's own declared disk size must agree with what the chunks add up to).
  /// Sizes come off a registry-supplied manifest, so the running total is checked rather than
  /// trusted not to overflow.
  public static func layout(
    of chunks: [OCIDescriptor], virtualSize: UInt64?, keys: ChunkAnnotationKeys = .runnerVM
  ) throws -> [PlacedChunk] {
    var offset: UInt64 = 0
    var placed: [PlacedChunk] = []
    for chunk in chunks {
      let size = try chunk.requiredUInt64Annotation(keys.uncompressedSize)
      let digest = try chunk.requiredAnnotation(keys.uncompressedDigest)
      placed.append(
        PlacedChunk(descriptor: chunk, offset: offset, uncompressedSize: size, uncompressedDigest: digest)
      )
      let (next, overflow) = offset.addingReportingOverflow(size)
      guard !overflow else {
        throw RegistryError.unsupportedManifest(
          reason: "chunk sizes overflow while summing the disk length"
        )
      }
      offset = next
    }
    if let virtualSize {
      guard offset == virtualSize else {
        throw RegistryError.unsupportedManifest(
          reason: "chunks describe \(offset) bytes but the disk is \(virtualSize)"
        )
      }
    }
    return placed
  }

  public static func totalBytes(_ placed: [PlacedChunk]) -> UInt64 {
    checkedSum(placed.map(\.uncompressedSize))
  }
}

/// Adds `values` with overflow reported rather than silently wrapped: sizes taken from a
/// registry-supplied manifest are an attacker-controlled input to a sum. Saturates at `UInt64.max`
/// instead of trapping, since every caller of this is a non-throwing size total.
func checkedSum(_ values: some Sequence<UInt64>) -> UInt64 {
  var total: UInt64 = 0
  for value in values {
    let (next, overflow) = total.addingReportingOverflow(value)
    total = overflow ? UInt64.max : next
  }
  return total
}
