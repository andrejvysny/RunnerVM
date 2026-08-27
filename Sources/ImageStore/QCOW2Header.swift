import Foundation

/// Why a qcow2 file cannot be converted. Every case is a refusal to guess: a converter that
/// silently produced zeros for a region it did not understand would hand the guest a corrupt disk.
public enum QCOW2Error: Error, Sendable, Equatable {
  case notQCOW2
  case unsupportedVersion(Int)
  case backingFileUnsupported
  case encryptionUnsupported
  /// Any incompatible feature bit this reader does not implement: dirty (0), corrupt (1),
  /// external data file (2), extended L2 entries (4), or an unknown future bit.
  case unsupportedIncompatibleFeatures(UInt64)
  /// `compression_type` other than 0 (zlib) — currently only 1 (zstd).
  case unsupportedCompression(Int)
  case corruptTable(String)
  case truncated
}

extension QCOW2Error: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notQCOW2: "not a qcow2 file"
    case let .unsupportedVersion(version): "unsupported qcow2 version \(version)"
    case .backingFileUnsupported: "qcow2 backing files are not supported"
    case .encryptionUnsupported: "encrypted qcow2 images are not supported"
    case let .unsupportedIncompatibleFeatures(bits):
      "unsupported qcow2 incompatible features 0x\(String(bits, radix: 16))"
    case let .unsupportedCompression(type): "unsupported qcow2 compression type \(type)"
    case let .corruptTable(reason): "corrupt qcow2 metadata: \(reason)"
    case .truncated: "qcow2 file is truncated"
    }
  }
}

/// The qcow2 v2/v3 header, big-endian on disk (QEMU `docs/interop/qcow2.rst`, "Header").
public struct QCOW2Header: Sendable, Equatable {
  public var version: Int
  public var clusterBits: Int
  public var clusterSize: Int
  public var virtualSize: UInt64
  public var l1Size: Int
  public var l1TableOffset: UInt64
  public var refcountTableOffset: UInt64
  public var refcountTableClusters: Int
  public var cryptMethod: UInt32
  public var backingFileOffset: UInt64
  public var backingFileSize: UInt32
  public var incompatibleFeatures: UInt64
  public var compatibleFeatures: UInt64
  public var autoclearFeatures: UInt64
  public var refcountOrder: Int
  public var headerLength: Int
  /// v3 only, byte 104 when `headerLength > 104`. 0 = zlib (the default), 1 = zstd.
  public var compressionType: Int

  /// Number of L2 entries in one cluster. Extended L2 entries are rejected before this is used.
  public var l2Entries: Int { clusterSize / 8 }

  /// Virtual bytes one L1 entry (one full L2 table) covers.
  public var bytesPerL1Entry: UInt64 { UInt64(l2Entries) * UInt64(clusterSize) }
}

public extension QCOW2Header {
  static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB] // "QFI\xfb"
  /// qcow2 allows 512 B … 2 MiB clusters; anything else is a hostile or corrupt header.
  static let minClusterBits = 9
  static let maxClusterBits = 21
  /// Sanity ceilings so a hostile header cannot make this reader allocate or truncate absurdly.
  static let maxVirtualSize: UInt64 = 4 << 40 // 4 TiB
  static let maxL1Entries = 1 << 20

  /// Bits 9-55 of an L1/L2 entry are the host offset; the rest are flags and reserved bits.
  static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
  static let compressedFlag: UInt64 = 1 << 62
  static let zeroFlag: UInt64 = 1

  // MARK: - Incompatible feature bits (qcow2.rst, "Header")

  static let featureDirty: UInt64 = 1 << 0
  static let featureCorrupt: UInt64 = 1 << 1
  static let featureExternalDataFile: UInt64 = 1 << 2
  static let featureCompressionType: UInt64 = 1 << 3
  static let featureExtendedL2: UInt64 = 1 << 4
}

extension QCOW2Header {
  /// Parses the fixed part of the header. `bytes` must hold at least `v2HeaderLength` bytes.
  static let v2HeaderLength = 72
  static let v3HeaderLength = 104

  static func parse(_ bytes: [UInt8]) throws -> QCOW2Header {
    guard bytes.count >= v2HeaderLength, Array(bytes[0..<4]) == magic else {
      throw QCOW2Error.notQCOW2
    }
    let version = Int(BigEndian.u32(bytes, 4))
    guard version == 2 || version == 3 else { throw QCOW2Error.unsupportedVersion(version) }

    let clusterBits = Int(BigEndian.u32(bytes, 20))
    guard clusterBits >= minClusterBits, clusterBits <= maxClusterBits else {
      throw QCOW2Error.corruptTable("cluster_bits \(clusterBits) out of range")
    }
    let virtualSize = BigEndian.u64(bytes, 24)
    guard virtualSize <= maxVirtualSize else {
      throw QCOW2Error.corruptTable("virtual size \(virtualSize) exceeds the supported maximum")
    }
    let l1Size = Int(BigEndian.u32(bytes, 36))
    guard l1Size <= maxL1Entries else {
      throw QCOW2Error.corruptTable("l1_size \(l1Size) exceeds the supported maximum")
    }

    var header = QCOW2Header(
      version: version, clusterBits: clusterBits, clusterSize: 1 << clusterBits,
      virtualSize: virtualSize, l1Size: l1Size, l1TableOffset: BigEndian.u64(bytes, 40),
      refcountTableOffset: BigEndian.u64(bytes, 48),
      refcountTableClusters: Int(BigEndian.u32(bytes, 56)),
      cryptMethod: BigEndian.u32(bytes, 32), backingFileOffset: BigEndian.u64(bytes, 8),
      backingFileSize: BigEndian.u32(bytes, 16), incompatibleFeatures: 0, compatibleFeatures: 0,
      autoclearFeatures: 0, refcountOrder: 4, headerLength: v2HeaderLength, compressionType: 0)
    guard version == 3 else { return header }

    guard bytes.count >= v3HeaderLength else { throw QCOW2Error.truncated }
    header.incompatibleFeatures = BigEndian.u64(bytes, 72)
    header.compatibleFeatures = BigEndian.u64(bytes, 80)
    header.autoclearFeatures = BigEndian.u64(bytes, 88)
    header.refcountOrder = Int(BigEndian.u32(bytes, 96))
    header.headerLength = Int(BigEndian.u32(bytes, 100))
    // The compression-type byte only exists once the header has been extended past the v3
    // baseline; older v3 images stop at 104 and are always zlib.
    if header.headerLength > 104, bytes.count > 104 {
      header.compressionType = Int(bytes[104])
    }
    return header
  }

  /// Everything `convertToRaw` refuses to handle. Kept out of `parse` so a caller that only wants
  /// to inspect an image still gets its header back.
  func validateConvertible() throws {
    guard backingFileOffset == 0, backingFileSize == 0 else {
      throw QCOW2Error.backingFileUnsupported
    }
    guard cryptMethod == 0 else { throw QCOW2Error.encryptionUnsupported }
    guard compressionType == 0 else { throw QCOW2Error.unsupportedCompression(compressionType) }
    // Bit 3 exists precisely to say `compression_type` is non-default, so seeing it alongside the
    // zlib value means the header contradicts itself and cannot be trusted.
    guard incompatibleFeatures & Self.featureCompressionType == 0 else {
      throw QCOW2Error.unsupportedCompression(compressionType)
    }
    // Dirty (0), corrupt (1), external data file (2) and extended L2 (4) all change how the
    // tables below must be read; so would any future bit.
    guard incompatibleFeatures == 0 else {
      throw QCOW2Error.unsupportedIncompatibleFeatures(incompatibleFeatures)
    }
  }
}

/// The qcow2 on-disk format is big-endian throughout.
enum BigEndian {
  static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    var value: UInt32 = 0
    for offset in 0..<4 { value = (value << 8) | UInt32(bytes[index + offset]) }
    return value
  }

  static func u64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
    var value: UInt64 = 0
    for offset in 0..<8 { value = (value << 8) | UInt64(bytes[index + offset]) }
    return value
  }
}

/// Bounds-checked random access over the source image. Every read is validated against the real
/// file length, so a header that points past the end fails as `truncated` rather than reading
/// whatever the kernel returns.
struct QCOW2File {
  let handle: FileHandle
  let size: UInt64

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    size = (try? FileSystem.fileSize(at: url)) ?? 0
  }

  func close() {
    try? handle.close()
  }

  func read(at offset: UInt64, count: Int) throws -> [UInt8] {
    guard count >= 0 else { throw QCOW2Error.corruptTable("negative read length") }
    guard offset <= size, UInt64(count) <= size - offset else { throw QCOW2Error.truncated }
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
      throw QCOW2Error.truncated
    }
    return [UInt8](data)
  }
}
