// Derived from openai/tart@16d186c Sources/tart/OCI/Digest.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import CryptoKit
import Foundation

/// `sha256:<hex>` over data, whole files, or byte ranges.
///
/// Ranged hashing is what makes a resumed pull cheap: a chunk already on disk is verified in place
/// instead of being downloaded again (spec §119).
public enum ContentDigest {
  /// Bounded so hashing an 80 GiB disk never maps it.
  public static let bufferBytes = 4 * 1024 * 1024

  public struct Streaming {
    private var hash = SHA256()

    public init() {}

    public mutating func update(_ data: some DataProtocol) {
      hash.update(data: data)
    }

    public func finalize() -> String {
      ContentDigest.format(hash.finalize())
    }
  }

  public static func hash(_ data: Data) -> String {
    format(SHA256.hash(data: data))
  }

  public static func hashFile(at url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    return try hash(file, limit: nil)
  }

  /// - Throws: `RegistryError.invalidResponse` when the range is not fully present in the file.
  public static func hashFile(at url: URL, offset: UInt64, size: UInt64) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let end = try file.seekToEnd()
    guard offset <= end, size <= end - offset else {
      throw RegistryError.invalidResponse(
        operation: "range digest", reason: "\(offset)+\(size) is outside a \(end)-byte file"
      )
    }
    try file.seek(toOffset: offset)
    return try hash(file, limit: size)
  }

  private static func hash(_ file: FileHandle, limit: UInt64?) throws -> String {
    var digest = Streaming()
    var remaining = limit
    while remaining.map({ $0 > 0 }) ?? true {
      let wanted = remaining.map { Int(min(UInt64(bufferBytes), $0)) } ?? bufferBytes
      let finished: Bool = try autoreleasepool {
        guard let chunk = try file.read(upToCount: wanted), !chunk.isEmpty else { return true }
        digest.update(chunk)
        remaining = remaining.map { $0 - UInt64(chunk.count) }
        return false
      }
      if finished { break }
    }
    return digest.finalize()
  }

  static func format(_ digest: SHA256.Digest) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}
