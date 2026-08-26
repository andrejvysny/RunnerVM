// Derived from openai/tart@16d186c Sources/tart/OCI/Digest.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import CryptoKit
import Foundation

/// Streaming SHA-256. Image disks are tens of gigabytes, so hashing reads a bounded window and
/// scopes Foundation's temporary read buffers to one chunk instead of mapping the whole file.
enum SHA256Hasher {
  static let bufferSize = 4 * 1024 * 1024

  static func hash(_ data: Data) -> String {
    format(SHA256.hash(data: data))
  }

  static func hashFile(at url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while true {
      let reachedEnd: Bool = try autoreleasepool {
        guard let chunk = try file.read(upToCount: bufferSize), !chunk.isEmpty else { return true }
        digest.update(data: chunk)
        return false
      }
      if reachedEnd { break }
    }
    return format(digest.finalize())
  }

  private static func format(_ digest: SHA256.Digest) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Deterministic JSON: sorted keys and unescaped slashes, so the same logical value always hashes to
/// the same digest. Every file this module writes is encoded through here.
enum CanonicalJSON {
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}
