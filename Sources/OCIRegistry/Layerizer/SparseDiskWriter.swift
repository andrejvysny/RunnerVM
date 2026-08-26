// Derived from openai/tart@16d186c Sources/tart/OCI/Layerizer/DiskV2.swift:263-299
// (`zeroSkippingWrite`) — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation

/// Writes a decompressed disk chunk while keeping the file sparse.
///
/// A 100 GiB runner image is mostly zeros. Writing them would allocate the whole thing, so runs of
/// zeros are either skipped (fresh file, already zero after `truncate`) or punched out with
/// `F_PUNCHHOLE` (resumed file, which may hold stale bytes from the interrupted attempt).
///
/// Not `Sendable`: exactly one task owns one writer.
final class SparseDiskWriter {
  /// Comparing whole 4 MiB blocks against a zero block is orders of magnitude faster than any
  /// per-byte scan, and a false negative costs one wasted block per chunk at worst.
  static let holeGranularity = 4 * 1024 * 1024
  private static let zeroBlock = Data(count: SparseDiskWriter.holeGranularity)

  private let handle: FileHandle
  private let blockSize: UInt64
  /// True when the file already held data: zeros then have to be punched, not skipped.
  private let punchHoles: Bool
  private var offset: UInt64
  private var pending = Data()

  init(url: URL, startingAt offset: UInt64, punchHoles: Bool) throws {
    handle = try FileHandle(forWritingTo: url)
    self.offset = offset
    self.punchHoles = punchHoles
    var info = stat()
    blockSize = stat(url.path(percentEncoded: false), &info) == 0 ? UInt64(info.st_blksize) : 4096
    pending.reserveCapacity(Self.holeGranularity)
  }

  /// Accumulates into blocks aligned to `holeGranularity` in *file* coordinates, so hole detection
  /// does not depend on how the decompressor happens to slice its output.
  func write(_ data: Data) throws {
    var slice = data[data.startIndex...]
    while !slice.isEmpty {
      let target = Int(UInt64(Self.holeGranularity) - (offset % UInt64(Self.holeGranularity)))
      let take = min(target - pending.count, slice.count)
      pending.append(contentsOf: slice.prefix(take))
      slice = slice.dropFirst(take)
      if pending.count == target { try flush() }
    }
  }

  func close() throws {
    try flush()
    try handle.synchronize()
    try handle.close()
  }

  private func flush() throws {
    guard !pending.isEmpty else { return }
    try emit(pending, at: offset)
    offset += UInt64(pending.count)
    pending.removeAll(keepingCapacity: true)
  }

  private func emit(_ block: Data, at offset: UInt64) throws {
    let isZero = block.count == Self.holeGranularity
      ? block == Self.zeroBlock
      : block == Self.zeroBlock.prefix(block.count)
    guard isZero else {
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: block)
      return
    }
    guard punchHoles else { return }
    if offset % blockSize == 0, UInt64(block.count) % blockSize == 0 {
      try punchHole(at: offset, length: block.count)
    } else {
      // An unaligned tail cannot be a hole, so overwrite whatever the interrupted pull left.
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: block)
    }
  }

  private func punchHole(at offset: UInt64, length: Int) throws {
    var argument = fpunchhole_t(
      fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(length)
    )
    guard fcntl(handle.fileDescriptor, F_PUNCHHOLE, &argument) != -1 else {
      throw RegistryError.invalidResponse(
        operation: "punch hole at \(offset)", reason: String(cString: strerror(errno))
      )
    }
  }
}
