import Compression
import Foundation

/// Read-only qcow2 → sparse raw conversion.
///
/// The VM worker can only boot a raw disk, so an image published as qcow2 (which is how most
/// upstream cloud images ship) has to be flattened once, at import. Only the mapping is read:
/// refcounts, snapshots and the L1/L2 "refcount is exactly one" bits describe how a *writer* would
/// have to behave and are irrelevant to a one-shot copy.
public enum QCOW2Reader {
  /// Whole 4 MiB blocks are compared against zero in one pass; a false negative costs one wasted
  /// block, never a wrong byte. Mirrors `SparseDiskWriter.holeGranularity` in OCIRegistry, which
  /// this deliberately does not import — ImageStore must not depend on the registry module.
  static let holeGranularity = 4 * 1024 * 1024
  /// Compressed cluster descriptors count 512-byte sectors regardless of the cluster size.
  static let compressedSectorSize = 512

  /// Cheap enough to run on every candidate file during import.
  public static func isQCOW2(url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let data = try handle.read(upToCount: QCOW2Header.magic.count),
          data.count == QCOW2Header.magic.count
    else { return false }
    return [UInt8](data) == QCOW2Header.magic
  }

  public static func header(url: URL) throws -> QCOW2Header {
    let file = try QCOW2File(url: url)
    defer { file.close() }
    return try header(of: file)
  }

  /// Converts `source` to a sparse raw file at `destination`, which is created (or replaced) and
  /// truncated to the image's virtual size — so every cluster this reader skips stays a hole.
  ///
  /// Unallocated clusters, and clusters carrying the v3 zero flag, are skipped. Compressed
  /// clusters are inflated; normal clusters are copied. Returns the number of bytes actually
  /// written, which is the non-hole size of the result. `progress` is invoked with that running
  /// total after each L2 table, so a caller can report import progress without per-cluster cost.
  @discardableResult
  public static func convertToRaw(
    source: URL, destination: URL, progress: (@Sendable (UInt64) -> Void)? = nil
  ) throws -> UInt64 {
    let file = try QCOW2File(url: source)
    defer { file.close() }
    let header = try header(of: file)
    try header.validateConvertible()

    try FileSystem.removeIfPresent(destination)
    try FileSystem.createEmptyFile(at: destination, mode: 0o644)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    try output.truncate(atOffset: header.virtualSize)

    var written: UInt64 = 0
    for (index, l2Offset) in try l1Table(file, header).enumerated() where l2Offset != 0 {
      written += try convert(
        l2At: l2Offset, l1Index: index, file: file, header: header, output: output)
      progress?(written)
    }
    try output.synchronize()
    return written
  }

  // MARK: - Tables

  private static func header(of file: QCOW2File) throws -> QCOW2Header {
    let length = min(Int(file.size), QCOW2Header.v3HeaderLength + 8)
    guard length >= QCOW2Header.v2HeaderLength else { throw QCOW2Error.notQCOW2 }
    return try QCOW2Header.parse(file.read(at: 0, count: length))
  }

  /// The L2 table offsets, one per L1 entry; `0` means the whole 512 MiB-ish range is unallocated.
  private static func l1Table(_ file: QCOW2File, _ header: QCOW2Header) throws -> [UInt64] {
    guard header.virtualSize > 0, header.bytesPerL1Entry > 0 else { return [] }
    let needed = Int(
      (header.virtualSize + header.bytesPerL1Entry - 1) / header.bytesPerL1Entry)
    guard needed <= header.l1Size else {
      throw QCOW2Error.corruptTable("l1_size \(header.l1Size) does not cover the virtual size")
    }
    guard header.l1TableOffset != 0,
          header.l1TableOffset % UInt64(header.clusterSize) == 0
    else {
      throw QCOW2Error.corruptTable("invalid l1_table_offset \(header.l1TableOffset)")
    }
    let raw = try file.read(at: header.l1TableOffset, count: needed * 8)
    return try (0..<needed).map { index in
      let offset = BigEndian.u64(raw, index * 8) & QCOW2Header.offsetMask
      guard offset % UInt64(header.clusterSize) == 0 else {
        throw QCOW2Error.corruptTable("unaligned L2 table offset \(offset)")
      }
      return offset
    }
  }

  /// One L2 table: `clusterSize / 8` standard or compressed cluster descriptors.
  private static func convert(
    l2At offset: UInt64, l1Index: Int, file: QCOW2File, header: QCOW2Header, output: FileHandle
  ) throws -> UInt64 {
    let table = try file.read(at: offset, count: header.clusterSize)
    var written: UInt64 = 0
    for index in 0..<header.l2Entries {
      let virtualOffset =
        (UInt64(l1Index) * UInt64(header.l2Entries) + UInt64(index)) * UInt64(header.clusterSize)
      guard virtualOffset < header.virtualSize else { break }
      let span = Int(min(UInt64(header.clusterSize), header.virtualSize - virtualOffset))
      guard let payload = try cluster(
        BigEndian.u64(table, index * 8), span: span, file: file, header: header)
      else { continue }
      written += try writeSkippingZeros(payload, at: virtualOffset, to: output)
    }
    return written
  }

  /// `nil` for a cluster that reads as zeros — unallocated, or carrying the v3 zero flag — which
  /// the caller leaves as a hole.
  private static func cluster(
    _ entry: UInt64, span: Int, file: QCOW2File, header: QCOW2Header
  ) throws -> [UInt8]? {
    // Checked first: in a compressed descriptor bit 0 belongs to the host offset, not to a flag.
    if entry & QCOW2Header.compressedFlag != 0 {
      return try inflate(entry, span: span, file: file, header: header)
    }
    guard entry & QCOW2Header.zeroFlag == 0 else { return nil }
    let host = entry & QCOW2Header.offsetMask
    guard host != 0 else { return nil }
    guard host % UInt64(header.clusterSize) == 0 else {
      throw QCOW2Error.corruptTable("unaligned data cluster offset \(host)")
    }
    return try file.read(at: host, count: span)
  }

  // MARK: - Compressed clusters

  /// Compressed Cluster Descriptor (QEMU `docs/interop/qcow2.rst`, "Cluster descriptors"), with
  /// `x = 62 - (cluster_bits - 8)`:
  ///
  ///   bits  0 … x-1 : host cluster offset — *not* aligned to a sector or cluster boundary
  ///   bits  x … 61  : number of *additional* 512-byte sectors beyond the one holding the offset
  ///   bit      62   : 1 (this cluster is compressed)
  ///
  /// so `offset = entry & ((1 << x) - 1)` and `sectors = ((entry >> x) & ((1 << (cluster_bits - 8))
  /// - 1)) + 1`, and the readable payload is `sectors * 512 - (offset % 512)` bytes — the same
  /// arithmetic QEMU's `qcow2_get_host_offset` performs. Decompression stops once a full cluster
  /// has been produced, so trailing bytes of the last sector may belong to another cluster.
  private static func inflate(
    _ entry: UInt64, span: Int, file: QCOW2File, header: QCOW2Header
  ) throws -> [UInt8] {
    let shift = UInt64(62 - (header.clusterBits - 8))
    let offset = entry & ((1 << shift) - 1)
    let sectors = ((entry >> shift) & ((1 << UInt64(header.clusterBits - 8)) - 1)) + 1
    guard offset < file.size else { throw QCOW2Error.truncated }
    let declared =
      Int(sectors) * compressedSectorSize - Int(offset % UInt64(compressedSectorSize))
    // The final sector of the image may be shorter than the descriptor's rounded-up span; the
    // deflate stream ends before it either way, so clamping is not data loss.
    let payload = try file.read(at: offset, count: min(declared, Int(file.size - offset)))
    let decoded = decode(payload, capacity: header.clusterSize)
    guard decoded.count >= span else {
      throw QCOW2Error.corruptTable(
        "compressed cluster at \(offset) inflated to \(decoded.count) of \(span) bytes")
    }
    return Array(decoded[0..<span])
  }

  /// qcow2 stores the deflate stream *without* the zlib header, which is exactly what
  /// `COMPRESSION_ZLIB` (RFC 1951 raw DEFLATE) expects.
  private static func decode(_ payload: [UInt8], capacity: Int) -> [UInt8] {
    payload.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return [] }
      return [UInt8](unsafeUninitializedCapacity: capacity) { buffer, count in
        count = compression_decode_buffer(
          buffer.baseAddress!, capacity, base, payload.count, nil, COMPRESSION_ZLIB)
      }
    }
  }

  // MARK: - Sparse output

  /// Writes `payload` at `offset`, skipping blocks that are entirely zero. The destination was
  /// truncated to its full size and never written before, so a skipped block is still unallocated
  /// — no `F_PUNCHHOLE` is needed. (APFS refuses to keep holes narrower than a few MiB, which is
  /// why `holeGranularity` is what it is; punching a smaller gap would only be filled back in.)
  /// Blocks are cut on `holeGranularity` boundaries in *file* coordinates so the decision does not
  /// depend on the cluster size.
  private static func writeSkippingZeros(
    _ payload: [UInt8], at offset: UInt64, to output: FileHandle
  ) throws -> UInt64 {
    var written: UInt64 = 0
    var index = 0
    var position = offset
    while index < payload.count {
      let toBoundary = Int(UInt64(holeGranularity) - position % UInt64(holeGranularity))
      let take = min(toBoundary, payload.count - index)
      let block = payload[index..<(index + take)]
      if block.contains(where: { $0 != 0 }) {
        try output.seek(toOffset: position)
        try output.write(contentsOf: Data(block))
        written += UInt64(take)
      }
      index += take
      position += UInt64(take)
    }
    return written
  }
}
