import Foundation
import ImageStore
import RunnerCore

/// A `FROM cloud-image:` base, ready to clone: a sparse raw disk plus the two digests provenance
/// records (the artifact as published, and the raw disk it converted to).
public struct FetchedBaseImage: Sendable, Hashable {
  /// Raw disk in the cache. Never handed to a VM directly -- `BuildStore` clones it.
  public var raw: URL
  /// `sha256:<hex>` of the file exactly as downloaded (the qcow2, when it was one).
  public var sourceSHA256: String
  /// `sha256:<hex>` of the converted raw disk.
  public var rawSHA256: String
  public var virtualBytes: UInt64
  /// URL or absolute path the bytes came from.
  public var source: String
  public var cacheHit: Bool

  public init(
    raw: URL, sourceSHA256: String, rawSHA256: String, virtualBytes: UInt64, source: String,
    cacheHit: Bool
  ) {
    self.raw = raw
    self.sourceSHA256 = sourceSHA256
    self.rawSHA256 = rawSHA256
    self.virtualBytes = virtualBytes
    self.source = source
    self.cacheHit = cacheHit
  }
}

/// The seam a bootstrap build reaches the network through. `BaseImageCache` is production; tests
/// inject a fetcher that hands back a prepared file, so nothing in the suite downloads a cloud
/// image or shells out to a converter.
public protocol BaseImageFetcher: Sendable {
  func fetch(location: String, sha256: String, noCache: Bool) async throws -> FetchedBaseImage
}

/// Downloads, verifies and converts the stock cloud disk a bootstrap recipe starts from (B2).
///
/// The digest in the recipe is over the artifact **as published** -- cloud vendors publish qcow2 --
/// so verification happens before any conversion, and the raw disk's own digest is recorded
/// separately in a sidecar so a cache hit can be re-validated without re-hashing 3 GiB.
public actor BaseImageCache: BaseImageFetcher {
  private let directory: URL
  private let reserveBytes: UInt64
  private let session: URLSession

  public init(directory: URL, reserveBytes: UInt64 = 0, session: URLSession = .shared) {
    self.directory = directory
    self.reserveBytes = reserveBytes
    self.session = session
  }

  private struct Sidecar: Codable {
    var sourceSHA256: String
    var rawSHA256: String
    var virtualSize: UInt64
  }

  public func fetch(location: String, sha256: String, noCache: Bool) async throws -> FetchedBaseImage {
    let key = Self.normalize(sha256)
    let raw = directory.appending(path: "base-\(key).raw")
    let sidecar = directory.appending(path: "base-\(key).json")
    if !noCache, let hit = cached(raw: raw, sidecar: sidecar, location: location) { return hit }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let downloaded = try await materialize(location: location, key: key)
    defer { try? FileManager.default.removeItem(at: downloaded) }

    let sourceDigest = try SHA256Digest.file(at: downloaded)
    guard sourceDigest == "sha256:" + key else {
      throw ImageBuildError.baseDigestMismatch(expected: "sha256:" + key, actual: sourceDigest)
    }
    try? FileManager.default.removeItem(at: raw)
    if try QCOW2Reader.isQCOW2(url: downloaded) {
      _ = try QCOW2Reader.convertToRaw(source: downloaded, destination: raw)
    } else {
      try FileManager.default.copyItem(at: downloaded, to: raw)
    }
    try Self.requirePartitioned(raw)
    let rawDigest = try SHA256Digest.file(at: raw)
    let size = Self.size(of: raw)
    try? JSONEncoder().encode(
      Sidecar(sourceSHA256: sourceDigest, rawSHA256: rawDigest, virtualSize: size)
    ).write(to: sidecar)
    return FetchedBaseImage(
      raw: raw, sourceSHA256: sourceDigest, rawSHA256: rawDigest, virtualBytes: size,
      source: location, cacheHit: false)
  }

  // MARK: - Cache

  /// A hit needs both the raw disk and its sidecar, and the disk has to still be the size the
  /// sidecar recorded -- a truncated cache entry is worse than a missing one.
  private func cached(raw: URL, sidecar: URL, location: String) -> FetchedBaseImage? {
    guard let data = try? Data(contentsOf: sidecar),
          let meta = try? JSONDecoder().decode(Sidecar.self, from: data),
          FileManager.default.fileExists(atPath: raw.path(percentEncoded: false)),
          Self.size(of: raw) == meta.virtualSize
    else { return nil }
    return FetchedBaseImage(
      raw: raw, sourceSHA256: meta.sourceSHA256, rawSHA256: meta.rawSHA256,
      virtualBytes: meta.virtualSize, source: location, cacheHit: true)
  }

  // MARK: - Transport

  /// Downloads to `<key>.part` and renames, so an interrupted transfer can never be mistaken for a
  /// complete artifact. A local absolute path is copied rather than used in place: the recipe's
  /// digest is verified against the copy the build will actually convert.
  private func materialize(location: String, key: String) async throws -> URL {
    let part = directory.appending(path: "base-\(key).part")
    try? FileManager.default.removeItem(at: part)
    if location.hasPrefix("/") {
      let source = URL(fileURLWithPath: location)
      guard FileManager.default.isReadableFile(atPath: location) else {
        throw ImageBuildError.contextUnreadable(path: location)
      }
      try checkFreeSpace(needed: Self.size(of: source) * 2)
      try FileManager.default.copyItem(at: source, to: part)
      return part
    }
    guard let url = URL(string: location), url.scheme == "https" else {
      throw ImageBuildError.baseFormatUnsupported(
        reason: "cloud-image location must be an https URL or an absolute path, got '\(location)'")
    }
    let (temporary, response) = try await session.download(from: url)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      try? FileManager.default.removeItem(at: temporary)
      throw ImageBuildError.baseFormatUnsupported(
        reason: "\(location) answered HTTP \(http.statusCode)")
    }
    try FileManager.default.moveItem(at: temporary, to: part)
    return part
  }

  private func checkFreeSpace(needed: UInt64) throws {
    let free = APFSClone.freeSpace(at: directory)
    let available = free > reserveBytes ? free - reserveBytes : 0
    guard needed <= available else {
      throw ImageBuildError.insufficientDisk(needed: needed, free: available)
    }
  }

  // MARK: - Validation

  /// A `FROM cloud-image:` base has to be a whole disk: GPT header at LBA 1, and definitively not a
  /// container this build failed to convert. The rootfs tarballs cloud vendors also publish look
  /// plausible until the VM refuses to boot, so they are refused here with the explanation.
  static func requirePartitioned(_ url: URL) throws {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let head = try handle.read(upToCount: 1_024), head.count >= 520
    else { throw ImageBuildError.baseNotPartitioned }
    defer { try? handle.close() }
    if head.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) {
      throw ImageBuildError.baseFormatUnsupported(reason: "still qcow2 after conversion")
    }
    let signature = head.subdata(in: 512..<520)
    guard signature == Data("EFI PART".utf8) else { throw ImageBuildError.baseNotPartitioned }
  }

  static func normalize(_ sha256: String) -> String {
    sha256.hasPrefix("sha256:") ? String(sha256.dropFirst("sha256:".count)) : sha256
  }

  static func size(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }
}
