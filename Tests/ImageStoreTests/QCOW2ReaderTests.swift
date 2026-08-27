import Compression
import Foundation
import Testing

@testable import ImageStore

/// Builds synthetic qcow2 v2/v3 images byte by byte, so the reader is exercised against the
/// on-disk format rather than against whatever `qemu-img` happens to be installed.
///
/// Layout: cluster 0 header, 1 refcount table, 2 refcount block, 3 L1 table, 4… L2 tables, then
/// data. Refcounts are left as zeros — the reader ignores them, and a read-only converter has no
/// reason to care.
struct QCOW2Builder {
  enum Cluster {
    case normal([UInt8])
    case compressed([UInt8])
    case zeroFlagged
  }

  var version = 3
  var clusterBits = 16
  var virtualSize: UInt64 = 8 << 20
  var magic = QCOW2Header.magic
  var backingFileOffset: UInt64 = 0
  var backingFileSize: UInt32 = 0
  var cryptMethod: UInt32 = 0
  var incompatibleFeatures: UInt64 = 0
  var compressionType = 0
  var headerLength = 112
  /// Leaves every L1 entry at 0, i.e. the whole image is unallocated.
  var unallocatedL1 = false
  /// Keyed by virtual cluster index.
  var clusters: [Int: Cluster] = [:]

  var clusterSize: Int { 1 << clusterBits }
  var l2Entries: Int { clusterSize / 8 }

  func build() -> Data {
    let perTable = UInt64(l2Entries * clusterSize)
    let l1Count = max(1, Int((virtualSize + perTable - 1) / perTable))
    var file = Data(count: clusterSize * (4 + l1Count))
    var tables = [[UInt64]](repeating: [UInt64](repeating: 0, count: l2Entries), count: l1Count)

    for (index, cluster) in clusters.sorted(by: { $0.key < $1.key }) {
      tables[index / l2Entries][index % l2Entries] = append(cluster, to: &file)
    }
    for (index, table) in tables.enumerated() {
      let base = clusterSize * (4 + index)
      for (entry, value) in table.enumerated() {
        Self.put64(&file, at: base + entry * 8, value)
      }
      let l1Entry = unallocatedL1 ? 0 : (UInt64(1) << 63) | UInt64(base)
      Self.put64(&file, at: clusterSize * 3 + index * 8, l1Entry)
    }
    writeHeader(&file, l1Count: l1Count)
    return file
  }

  /// Appends one cluster's host bytes and returns its L2 entry.
  private func append(_ cluster: Cluster, to file: inout Data) -> UInt64 {
    switch cluster {
    case .zeroFlagged:
      return QCOW2Header.zeroFlag
    case let .normal(bytes):
      let offset = UInt64(file.count)
      file.append(contentsOf: bytes)
      file.append(Data(count: clusterSize - bytes.count))
      // Bit 63 ("refcount is exactly one") is set the way qemu-img sets it, so the reader is
      // forced to mask rather than to read the entry raw.
      return (UInt64(1) << 63) | offset
    case let .compressed(bytes):
      // Three bytes of slack put the payload off any sector boundary, which is the case the
      // `sectors * 512 - (offset % 512)` length formula exists for.
      file.append(Data(count: 3))
      let offset = UInt64(file.count)
      let payload = QCOW2Builder.deflate(bytes)
      file.append(contentsOf: payload)
      let pad = (clusterSize - file.count % clusterSize) % clusterSize
      file.append(Data(count: pad))
      let span = Int(offset % 512) + payload.count
      let additional = UInt64((span + 511) / 512 - 1)
      let shift = UInt64(62 - (clusterBits - 8))
      return (UInt64(1) << 63) | QCOW2Header.compressedFlag | (additional << shift) | offset
    }
  }

  private func writeHeader(_ file: inout Data, l1Count: Int) {
    for (index, byte) in magic.enumerated() { file[index] = byte }
    Self.put32(&file, at: 4, UInt32(version))
    Self.put64(&file, at: 8, backingFileOffset)
    Self.put32(&file, at: 16, backingFileSize)
    Self.put32(&file, at: 20, UInt32(clusterBits))
    Self.put64(&file, at: 24, virtualSize)
    Self.put32(&file, at: 32, cryptMethod)
    Self.put32(&file, at: 36, UInt32(l1Count))
    Self.put64(&file, at: 40, UInt64(clusterSize * 3))
    Self.put64(&file, at: 48, UInt64(clusterSize))
    Self.put32(&file, at: 56, 1)
    guard version >= 3 else { return }
    Self.put64(&file, at: 72, incompatibleFeatures)
    Self.put32(&file, at: 96, 4)
    Self.put32(&file, at: 100, UInt32(headerLength))
    if headerLength > 104 { file[104] = UInt8(compressionType) }
  }

  // MARK: - Helpers

  static func put32(_ data: inout Data, at index: Int, _ value: UInt32) {
    for offset in 0..<4 { data[index + offset] = UInt8((value >> (8 * (3 - offset))) & 0xFF) }
  }

  static func put64(_ data: inout Data, at index: Int, _ value: UInt64) {
    for offset in 0..<8 { data[index + offset] = UInt8((value >> (8 * (7 - offset))) & 0xFF) }
  }

  /// Raw DEFLATE, which is exactly what qcow2 stores for a zlib-compressed cluster.
  static func deflate(_ bytes: [UInt8]) -> [UInt8] {
    let capacity = bytes.count * 2 + 4096
    var out = [UInt8](repeating: 0, count: capacity)
    let written = bytes.withUnsafeBufferPointer { source in
      out.withUnsafeMutableBufferPointer { destination in
        compression_encode_buffer(
          destination.baseAddress!, capacity, source.baseAddress!, bytes.count, nil,
          COMPRESSION_ZLIB)
      }
    }
    return Array(out[0..<written])
  }
}

/// `convertToRaw` calls `progress` synchronously on the calling thread, so no locking is needed
/// to collect what it reported.
final class Recorder: @unchecked Sendable {
  private(set) var values: [UInt64] = []

  func add(_ value: UInt64) {
    values.append(value)
  }
}

@Suite struct QCOW2ReaderTests {
  static let clusterSize = 64 << 10
  static let virtualSize: UInt64 = 8 << 20

  static func pattern(_ seed: UInt8) -> [UInt8] {
    (0..<clusterSize).map { UInt8((UInt($0) &* 31 &+ UInt(seed)) % 255 &+ 1) }
  }

  /// A cluster the deflater can actually shrink, with a non-zero marker so the sparse writer
  /// cannot skip it.
  static func compressible() -> [UInt8] {
    var bytes = [UInt8](repeating: 0xCC, count: clusterSize)
    for index in 0..<8 { bytes[index] = 0xDE }
    return bytes
  }

  private func write(_ builder: QCOW2Builder, in store: TempStore, named name: String) throws -> URL {
    let url = store.root.appending(path: name)
    try builder.build().write(to: url)
    return url
  }

  // MARK: - Conversion

  @Test func convertsNormalCompressedZeroAndUnallocatedClusters() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.clusters = [
      0: .normal(Self.pattern(1)),
      16: .compressed(Self.compressible()), // 1 MiB
      32: .zeroFlagged, // 2 MiB
      48: .normal(Self.pattern(7)), // 3 MiB
    ]
    let source = try write(builder, in: store, named: "mixed.qcow2")
    let destination = store.root.appending(path: "mixed.raw")

    let written = try QCOW2Reader.convertToRaw(source: source, destination: destination)

    var expected = [UInt8](repeating: 0, count: Int(Self.virtualSize))
    for (index, bytes) in [
      (0, Self.pattern(1)), (16, Self.compressible()), (48, Self.pattern(7)),
    ] {
      expected.replaceSubrange(
        (index * Self.clusterSize)..<((index + 1) * Self.clusterSize), with: bytes)
    }
    #expect(try Data(contentsOf: destination) == Data(expected))
    #expect(try FileSystem.fileSize(at: destination) == Self.virtualSize)
    // Three allocated clusters and nothing else: the holes never reach the filesystem.
    #expect(written == UInt64(3 * Self.clusterSize))
  }

  /// APFS refuses to keep holes narrower than a few MiB, so sparseness is asserted on an image
  /// whose allocated clusters are genuinely far apart — the shape a real cloud image has.
  @Test func outputStaysSparseAcrossLargeHoles() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.virtualSize = 256 << 20
    let first = Self.pattern(11)
    let last = Self.pattern(23)
    builder.clusters = [0: .normal(first), 2048: .normal(last)] // 0 and 128 MiB
    let source = try write(builder, in: store, named: "wide.qcow2")
    let destination = store.root.appending(path: "wide.raw")

    let written = try QCOW2Reader.convertToRaw(source: source, destination: destination)

    #expect(written == UInt64(2 * Self.clusterSize))
    #expect(try FileSystem.fileSize(at: destination) == 256 << 20)
    #expect(FileSystem.allocatedBytes(at: destination) < 8 << 20)
    let handle = try FileHandle(forReadingFrom: destination)
    defer { try? handle.close() }
    #expect(try handle.read(upToCount: Self.clusterSize) == Data(first))
    try handle.seek(toOffset: 128 << 20)
    #expect(try handle.read(upToCount: Self.clusterSize) == Data(last))
    try handle.seek(toOffset: 64 << 20)
    #expect(try handle.read(upToCount: 4096) == Data(count: 4096))
  }

  @Test func progressReportsTheRunningNonHoleTotal() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.clusters = [0: .normal(Self.pattern(3))]
    let source = try write(builder, in: store, named: "progress.qcow2")

    let reports = Recorder()
    let written = try QCOW2Reader.convertToRaw(
      source: source, destination: store.root.appending(path: "progress.raw"),
      progress: { reports.add($0) })

    #expect(reports.values == [written])
  }

  @Test func unallocatedL1EntryLeavesTheWholeImageAHole() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.unallocatedL1 = true
    builder.clusters = [0: .normal(Self.pattern(2))]
    let source = try write(builder, in: store, named: "empty.qcow2")
    let destination = store.root.appending(path: "empty.raw")

    #expect(try QCOW2Reader.convertToRaw(source: source, destination: destination) == 0)
    #expect(try FileSystem.fileSize(at: destination) == Self.virtualSize)
    #expect(FileSystem.allocatedBytes(at: destination) < 1 << 20)
  }

  @Test func overwritesAnExistingDestination() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.clusters = [0: .normal(Self.pattern(5))]
    let source = try write(builder, in: store, named: "again.qcow2")
    let destination = store.root.appending(path: "again.raw")
    try Data(repeating: 0xFF, count: 4096).write(to: destination)

    _ = try QCOW2Reader.convertToRaw(source: source, destination: destination)

    #expect(try FileSystem.fileSize(at: destination) == Self.virtualSize)
  }

  // MARK: - Header

  @Test func headerReportsTheSpecFields() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.clusters = [0: .normal(Self.pattern(1))]
    let source = try write(builder, in: store, named: "header.qcow2")

    let header = try QCOW2Reader.header(url: source)

    #expect(header.version == 3)
    #expect(header.clusterBits == 16)
    #expect(header.clusterSize == Self.clusterSize)
    #expect(header.virtualSize == Self.virtualSize)
    #expect(header.l1Size == 1)
    #expect(header.l1TableOffset == UInt64(Self.clusterSize * 3))
    #expect(header.refcountTableOffset == UInt64(Self.clusterSize))
    #expect(header.refcountTableClusters == 1)
    #expect(header.refcountOrder == 4)
    #expect(header.headerLength == 112)
    #expect(header.compressionType == 0)
    #expect(header.l2Entries == Self.clusterSize / 8)
    #expect(try QCOW2Reader.isQCOW2(url: source))
  }

  @Test func version2ImagesAreSupported() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.version = 2
    builder.clusters = [0: .normal(Self.pattern(9))]
    let source = try write(builder, in: store, named: "v2.qcow2")
    let destination = store.root.appending(path: "v2.raw")

    #expect(try QCOW2Reader.header(url: source).version == 2)
    #expect(try QCOW2Reader.convertToRaw(source: source, destination: destination)
      == UInt64(Self.clusterSize))
  }

  @Test func isQCOW2IsFalseForARawGPTStub() throws {
    let store = try TempStore()
    let url = store.root.appending(path: "raw.img")
    var stub = Data(count: 1 << 20)
    for (index, byte) in Array("EFI PART".utf8).enumerated() { stub[512 + index] = byte }
    try stub.write(to: url)

    #expect(try QCOW2Reader.isQCOW2(url: url) == false)
    #expect(throws: QCOW2Error.notQCOW2) { _ = try QCOW2Reader.header(url: url) }
  }

  @Test func isQCOW2IsFalseForAFileShorterThanTheMagic() throws {
    let store = try TempStore()
    let url = store.root.appending(path: "tiny.bin")
    try Data([0x51, 0x46]).write(to: url)

    #expect(try QCOW2Reader.isQCOW2(url: url) == false)
  }

  // MARK: - Rejections

  @Test func foreignMagicIsRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.magic = [0x51, 0x46, 0x49, 0xFA]
    let source = try write(builder, in: store, named: "other.img")

    #expect(try QCOW2Reader.isQCOW2(url: source) == false)
    #expect(throws: QCOW2Error.notQCOW2) { _ = try QCOW2Reader.header(url: source) }
  }

  @Test func version1IsRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.version = 1
    let source = try write(builder, in: store, named: "v1.qcow2")

    #expect(throws: QCOW2Error.unsupportedVersion(1)) { _ = try QCOW2Reader.header(url: source) }
  }

  @Test func backingFileIsRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.backingFileOffset = 0x200
    builder.backingFileSize = 12
    builder.clusters = [0: .normal(Self.pattern(1))]
    let source = try write(builder, in: store, named: "backed.qcow2")

    #expect(throws: QCOW2Error.backingFileUnsupported) {
      _ = try QCOW2Reader.convertToRaw(
        source: source, destination: store.root.appending(path: "backed.raw"))
    }
  }

  @Test func encryptionIsRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.cryptMethod = 1
    builder.clusters = [0: .normal(Self.pattern(1))]
    let source = try write(builder, in: store, named: "crypt.qcow2")

    #expect(throws: QCOW2Error.encryptionUnsupported) {
      _ = try QCOW2Reader.convertToRaw(
        source: source, destination: store.root.appending(path: "crypt.raw"))
    }
  }

  @Test func extendedL2EntriesAreRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.incompatibleFeatures = QCOW2Header.featureExtendedL2
    builder.clusters = [0: .normal(Self.pattern(1))]
    let source = try write(builder, in: store, named: "extl2.qcow2")

    #expect(throws: QCOW2Error.unsupportedIncompatibleFeatures(QCOW2Header.featureExtendedL2)) {
      _ = try QCOW2Reader.convertToRaw(
        source: source, destination: store.root.appending(path: "extl2.raw"))
    }
  }

  @Test func dirtyAndExternalDataFileBitsAreRejected() throws {
    let store = try TempStore()
    for (name, bits) in [
      ("dirty", QCOW2Header.featureDirty), ("external", QCOW2Header.featureExternalDataFile),
    ] {
      var builder = QCOW2Builder()
      builder.incompatibleFeatures = bits
      builder.clusters = [0: .normal(Self.pattern(1))]
      let source = try write(builder, in: store, named: "\(name).qcow2")

      #expect(throws: QCOW2Error.unsupportedIncompatibleFeatures(bits)) {
        _ = try QCOW2Reader.convertToRaw(
          source: source, destination: store.root.appending(path: "\(name).raw"))
      }
    }
  }

  @Test func zstdCompressionIsRejected() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.compressionType = 1
    builder.incompatibleFeatures = QCOW2Header.featureCompressionType
    builder.clusters = [0: .normal(Self.pattern(1))]
    let source = try write(builder, in: store, named: "zstd.qcow2")

    #expect(throws: QCOW2Error.unsupportedCompression(1)) {
      _ = try QCOW2Reader.convertToRaw(
        source: source, destination: store.root.appending(path: "zstd.raw"))
    }
  }

  @Test func truncatedTablesAreReportedNotCrashed() throws {
    let store = try TempStore()
    var builder = QCOW2Builder()
    builder.clusters = [0: .normal(Self.pattern(1)), 48: .normal(Self.pattern(7))]
    let full = builder.build()

    // Cut before the L1 table, and again in the middle of the data clusters.
    for (name, length) in [("head", Self.clusterSize + 100), ("body", Self.clusterSize * 5 + 64)] {
      let source = store.root.appending(path: "\(name).qcow2")
      try full.prefix(length).write(to: source)

      #expect(throws: QCOW2Error.truncated) {
        _ = try QCOW2Reader.convertToRaw(
          source: source, destination: store.root.appending(path: "\(name).raw"))
      }
    }
  }

  /// Hostile headers are patched into an otherwise valid image rather than built, so the builder
  /// never has to materialize the absurd geometry they claim.
  @Test func hostileGeometryIsRejected() throws {
    let store = try TempStore()
    let valid = QCOW2Builder().build()

    for (name, patch) in [
      ("huge", { (bytes: inout Data) in
        QCOW2Builder.put64(&bytes, at: 24, QCOW2Header.maxVirtualSize + 1)
      }),
      ("bits", { bytes in QCOW2Builder.put32(&bytes, at: 20, 63) }),
      ("l1", { bytes in QCOW2Builder.put32(&bytes, at: 36, UInt32(QCOW2Header.maxL1Entries + 1)) }),
    ] {
      var bytes = valid
      patch(&bytes)
      let source = store.root.appending(path: "\(name).qcow2")
      try bytes.write(to: source)

      #expect(throws: QCOW2Error.self) { _ = try QCOW2Reader.header(url: source) }
    }
  }

  /// An `l1_size` too small to describe the virtual size would silently zero-fill the tail.
  @Test func anL1TableTooSmallForTheVirtualSizeIsRejected() throws {
    let store = try TempStore()
    var bytes = QCOW2Builder().build()
    QCOW2Builder.put32(&bytes, at: 36, 0)
    let source = store.root.appending(path: "short-l1.qcow2")
    try bytes.write(to: source)

    #expect(throws: QCOW2Error.self) {
      _ = try QCOW2Reader.convertToRaw(
        source: source, destination: store.root.appending(path: "short-l1.raw"))
    }
  }
}
