import Foundation
import ImageStore
import Logging
import Metrics
import RunnerCore
import RunnerLogging

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

/// Downloads, verifies and converts the stock cloud disk a bootstrap recipe starts from (B2), and
/// keeps a **bounded** LRU cache of the results.
///
/// The digest in the recipe is over the artifact **as published** -- cloud vendors publish qcow2 --
/// so verification happens before any conversion, and the raw disk's own digest is recorded
/// separately in a sidecar so a cache hit can be re-validated without re-hashing 3 GiB.
///
/// Bounding rules, in the order they bind: a base pinned by a live `image_builds` row (or by a
/// fetch this process is running) is never evicted, even if that means refusing the new fetch;
/// otherwise the least-recently-used entries go until `maxBytes`, `maxEntries` and the host
/// free-space floor all hold. An entry becomes visible only once both its raw disk and its sidecar
/// are in place, so a crash mid-conversion leaves nothing a later run can mistake for a hit.
public actor BaseImageCache: BaseImageFetcher {
  /// One committed cache entry. `bytes` is *allocated* size, not the sparse logical size the
  /// sidecar records: the quota exists to bound what the volume actually gives up.
  struct Entry: Sendable, Hashable {
    var key: String
    var bytes: UInt64
    var lastUsedAt: Date
  }

  struct Sidecar: Codable, Sendable, Hashable {
    var sourceSHA256: String
    var rawSHA256: String
    var virtualSize: UInt64
    /// Absent in sidecars written before the cache was bounded; the index falls back to the raw
    /// disk's mtime so an upgraded host starts with a plausible LRU order instead of a flat one.
    var lastUsedAt: Date?
  }

  let directory: URL
  let policy: BaseImageCachePolicy
  let reserveBytes: UInt64
  /// sha256 keys that must survive eviction: `ImageBuilder` answers with the base of every
  /// non-terminal build row, so nothing has to be re-registered after a daemon restart.
  let pinned: @Sendable () async -> Set<String>
  let metrics: MetricRegistry?
  /// Injected so a test can drive the free-space floor without filling a real volume.
  let freeSpaceProbe: @Sendable (URL) -> UInt64
  let session: URLSession
  let now: @Sendable () -> Date
  let logger: Logger

  var index: [String: Entry] = [:]
  var indexed = false
  /// One transfer per key however many builds asked for it, and a pin for its whole duration.
  var inFlight: [String: Task<FetchedBaseImage, any Error>] = [:]
  /// Transfers this process actually ran. Exists so the "N callers, one download" guarantee above
  /// is observable rather than merely intended.
  private(set) var transferCount = 0

  public init(
    directory: URL,
    policy: BaseImageCachePolicy = BaseImageCachePolicy(),
    reserveBytes: UInt64 = 0,
    pinned: @escaping @Sendable () async -> Set<String> = { [] },
    metrics: MetricRegistry? = nil,
    freeSpace: @escaping @Sendable (URL) -> UInt64 = { APFSClone.freeSpace(at: $0) },
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .image)
  ) {
    self.directory = directory
    self.policy = policy
    self.reserveBytes = reserveBytes
    self.pinned = pinned
    self.metrics = metrics
    self.freeSpaceProbe = freeSpace
    self.session = session
    self.now = now
    self.logger = logger
  }

  // MARK: - BaseImageFetcher

  public func fetch(location: String, sha256: String, noCache: Bool) async throws -> FetchedBaseImage {
    let key = Self.normalize(sha256)
    await prepare()
    if !noCache, let hit = touch(key: key, location: location) { return hit }
    // Nothing between the miss and the registration below may suspend, or two builds naming the
    // same digest would each start their own download (mirrors `ImageManager.pull`).
    if let running = inFlight[key] { return try await running.value }
    return try await launch(location: location, key: key).value
  }

  /// Synchronous on purpose -- see `fetch`. A hit needs both the raw disk and its sidecar, and the
  /// disk has to still be the size the sidecar recorded: a truncated cache entry is worse than a
  /// missing one. The freshened `lastUsedAt` is what makes eviction LRU rather than arbitrary.
  private func touch(key: String, location: String) -> FetchedBaseImage? {
    let raw = rawURL(key)
    guard var meta = Self.readSidecar(at: sidecarURL(key)),
          FileManager.default.fileExists(atPath: raw.path(percentEncoded: false)),
          Self.size(of: raw) == meta.virtualSize
    else { return nil }
    let at = now()
    meta.lastUsedAt = at
    try? Self.writeSidecar(meta, to: sidecarURL(key))
    index[key] = Entry(key: key, bytes: Self.allocatedSize(of: raw), lastUsedAt: at)
    return FetchedBaseImage(
      raw: raw, sourceSHA256: meta.sourceSHA256, rawSHA256: meta.rawSHA256,
      virtualBytes: meta.virtualSize, source: location, cacheHit: true)
  }

  /// Synchronous registration for the same reason `touch` is: the entry has to be published before
  /// the first suspension point, so the transfer itself starts as a child task.
  private func launch(location: String, key: String) -> Task<FetchedBaseImage, any Error> {
    let task = Task<FetchedBaseImage, any Error> {
      try await self.perform(location: location, key: key)
    }
    inFlight[key] = task
    return task
  }

  private func perform(location: String, key: String) async throws -> FetchedBaseImage {
    // Held until the very end so the entry this fetch just committed cannot be evicted by the
    // post-commit sweep it triggers itself.
    defer { inFlight[key] = nil }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let fetched = try await download(location: location, key: key)
      await enforceQuotas()
      await publish()
      return fetched
    } catch {
      discardPartials(key: key)
      await publish()
      throw error
    }
  }

  /// Fetch → verify → convert → commit. Every failure leaves the cache exactly as it found it:
  /// the partials are named `.part` and swept by `discardPartials`, and the entry only becomes
  /// visible once the raw disk *and* its sidecar are both in place.
  private func download(location: String, key: String) async throws -> FetchedBaseImage {
    try await makeRoom(needed: await estimatedBytes(of: location), arriving: key)
    let part = partURL(key)
    try await materialize(location: location, into: part)
    let sourceDigest = try SHA256Digest.file(at: part)
    guard sourceDigest == "sha256:" + key else {
      throw ImageBuildError.baseDigestMismatch(expected: "sha256:" + key, actual: sourceDigest)
    }
    // Re-checked with a real size now that the artifact is on disk: the pre-download estimate was
    // a `Content-Length` at best, and the conversion writes a second copy alongside it.
    try await makeRoom(needed: Self.allocatedSize(of: part), arriving: key)
    let rawPart = rawPartURL(key)
    if try QCOW2Reader.isQCOW2(url: part) {
      _ = try QCOW2Reader.convertToRaw(source: part, destination: rawPart)
    } else {
      try? FileManager.default.removeItem(at: rawPart)
      try FileManager.default.copyItem(at: part, to: rawPart)
    }
    try Self.requirePartitioned(rawPart)
    let rawDigest = try SHA256Digest.file(at: rawPart)
    try? FileManager.default.removeItem(at: part)
    return try commit(key: key, sourceDigest: sourceDigest, rawDigest: rawDigest, source: location)
  }

  /// The atomic half: the sidecar goes away first, then the raw disk is replaced, then the sidecar
  /// is written back. Every intermediate state on disk is either "nothing" or "a raw disk with no
  /// sidecar" -- both of which the index scan sweeps, and neither of which reads as a hit.
  private func commit(
    key: String, sourceDigest: String, rawDigest: String, source: String
  ) throws -> FetchedBaseImage {
    let raw = rawURL(key)
    index[key] = nil
    try? FileManager.default.removeItem(at: sidecarURL(key))
    try? FileManager.default.removeItem(at: raw)
    try FileManager.default.moveItem(at: rawPartURL(key), to: raw)
    let size = Self.size(of: raw)
    let at = now()
    try Self.writeSidecar(
      Sidecar(
        sourceSHA256: sourceDigest, rawSHA256: rawDigest, virtualSize: size, lastUsedAt: at),
      to: sidecarURL(key))
    index[key] = Entry(key: key, bytes: Self.allocatedSize(of: raw), lastUsedAt: at)
    return FetchedBaseImage(
      raw: raw, sourceSHA256: sourceDigest, rawSHA256: rawDigest, virtualBytes: size,
      source: source, cacheHit: false)
  }

  private func discardPartials(key: String) {
    for url in [partURL(key), rawPartURL(key), sidecarPartURL(key)] {
      try? FileManager.default.removeItem(at: url)
    }
    // A commit that died between removing the old sidecar and writing the new one leaves a raw
    // disk nothing can validate; drop it rather than wait for the next process to sweep it.
    if Self.readSidecar(at: sidecarURL(key)) == nil {
      try? FileManager.default.removeItem(at: rawURL(key))
      index[key] = nil
    }
  }

  // MARK: - Transport

  /// Downloads to `<key>.part` and renames, so an interrupted transfer can never be mistaken for a
  /// complete artifact. A local absolute path is copied rather than used in place: the recipe's
  /// digest is verified against the copy the build will actually convert.
  private func materialize(location: String, into part: URL) async throws {
    try? FileManager.default.removeItem(at: part)
    if location.hasPrefix("/") {
      guard FileManager.default.isReadableFile(atPath: location) else {
        throw ImageBuildError.contextUnreadable(path: location)
      }
      transferCount += 1
      try FileManager.default.copyItem(at: URL(fileURLWithPath: location), to: part)
      return
    }
    let url = try Self.httpsURL(location)
    transferCount += 1
    let (temporary, response) = try await session.download(from: url)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      try? FileManager.default.removeItem(at: temporary)
      throw ImageBuildError.baseFormatUnsupported(
        reason: "\(location) answered HTTP \(http.statusCode)")
    }
    try FileManager.default.moveItem(at: temporary, to: part)
  }

  /// What this fetch is about to cost the volume: the artifact and the raw disk it converts to
  /// live side by side until the conversion finishes, hence twice the source size. An https base
  /// whose server declines to answer `HEAD` with a length budgets as 0 -- unknown, not free: the
  /// free-space floor below still has to have room to spare before anything is downloaded.
  private func estimatedBytes(of location: String) async -> UInt64 {
    if location.hasPrefix("/") {
      return Self.allocatedSize(of: URL(fileURLWithPath: location)).multipliedOrMax(by: 2)
    }
    guard let url = try? Self.httpsURL(location) else { return 0 }
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    guard let (_, response) = try? await session.data(for: request),
          response.expectedContentLength > 0
    else { return 0 }
    return UInt64(response.expectedContentLength).multipliedOrMax(by: 2)
  }

  static func httpsURL(_ location: String) throws -> URL {
    guard let url = URL(string: location), url.scheme == "https" else {
      throw ImageBuildError.baseFormatUnsupported(
        reason: "cloud-image location must be an https URL or an absolute path, got '\(location)'")
    }
    return url
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
}

extension UInt64 {
  /// Saturating rather than trapping: these are budget estimates derived from a `Content-Length` a
  /// remote server chose, and a build must fail closed on an absurd one, never crash the daemon.
  func multipliedOrMax(by factor: UInt64) -> UInt64 {
    let (product, overflow) = multipliedReportingOverflow(by: factor)
    return overflow ? .max : product
  }

  func addedOrMax(_ other: UInt64) -> UInt64 {
    let (sum, overflow) = addingReportingOverflow(other)
    return overflow ? .max : sum
  }
}
