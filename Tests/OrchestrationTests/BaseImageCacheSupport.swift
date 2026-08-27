import Foundation
import Metrics
import RunnerCore
import Testing

@testable import Orchestration

/// Fixture for `BaseImageCacheTests`: a scratch cache directory plus synthetic "cloud images".
///
/// Every base is an ordinary local file with `EFI PART` at offset 512, referenced by its absolute
/// path, so the suite exercises the real fetch/verify/commit ladder without a network, a converter
/// or a multi-gigabyte download.
struct BaseImageCacheFixture {
  let root: URL
  let cacheDir: URL
  /// Allocated bytes one committed entry costs. Measured, not assumed, so the quota arithmetic in
  /// the tests is exact whatever the volume's block size turns out to be.
  let unit: UInt64

  static let baseBytes = 1 << 20

  init() throws {
    root = URL(fileURLWithPath: "/tmp/rvm-cache-\(UUID().uuidString.prefix(8))", isDirectory: true)
    cacheDir = root.appending(path: "base-images", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let probe = try Self.write(
      bytes: Data(repeating: 0x5A, count: Self.baseBytes), to: root.appending(path: "probe.img"))
    unit = BaseImageCache.allocatedSize(of: probe)
    try FileManager.default.removeItem(at: probe)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }

  /// A distinct synthetic base. `fill` makes the content -- and therefore the sha256 key -- unique.
  func source(_ name: String, fill: UInt8) throws -> Source {
    var bytes = Data(repeating: fill, count: Self.baseBytes)
    bytes.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
    let url = try Self.write(bytes: bytes, to: root.appending(path: "\(name).img"))
    let digest = try SHA256Digest.file(at: url)
    return Source(url: url, digest: digest, key: BaseImageCache.normalize(digest))
  }

  struct Source: Sendable {
    let url: URL
    /// `sha256:<hex>`, as a recipe would spell it.
    let digest: String
    let key: String

    var path: String { url.path(percentEncoded: false) }
  }

  /// `capacity` models a volume the cache is the only writer of: the free-space probe answers
  /// with what is left of it, so eviction actually buys headroom the way it does on a real host.
  /// Left `nil`, free space is effectively unlimited and only the byte/entry quotas bind.
  func cache(
    policy: BaseImageCachePolicy,
    capacity: UInt64? = nil,
    reserveBytes: UInt64 = 0,
    pinned: @escaping @Sendable () async -> Set<String> = { [] },
    metrics: MetricRegistry? = nil,
    clock: StepClock = StepClock()
  ) -> BaseImageCache {
    let directory = cacheDir
    let probe: @Sendable (URL) -> UInt64 = { _ in
      guard let capacity else { return 1 << 40 }
      let used = BaseImageCacheFixture.usedBytes(in: directory)
      return capacity > used ? capacity - used : 0
    }
    return BaseImageCache(
      directory: cacheDir, policy: policy, reserveBytes: reserveBytes, pinned: pinned,
      metrics: metrics, freeSpace: probe, now: { clock.next() })
  }

  static func usedBytes(in directory: URL) -> UInt64 {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    return names.reduce(UInt64(0)) {
      $0 + BaseImageCache.allocatedSize(of: directory.appending(path: $1))
    }
  }

  // MARK: - Assertions

  func hasEntry(_ source: Source) -> Bool {
    let exists: (String) -> Bool = {
      FileManager.default.fileExists(
        atPath: cacheDir.appending(path: "base-\(source.key).\($0)").path(percentEncoded: false))
    }
    return exists("raw") && exists("json")
  }

  /// Everything in the cache directory, so a test can assert that a failure left nothing behind.
  var files: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path(percentEncoded: false))) ?? [])
      .sorted()
  }

  func sidecar(_ source: Source) -> BaseImageCache.Sidecar? {
    BaseImageCache.readSidecar(at: cacheDir.appending(path: "base-\(source.key).json"))
  }

  func plant(_ name: String) throws {
    try Data("leftover".utf8).write(to: cacheDir.appending(path: name))
  }

  @discardableResult
  private static func write(bytes: Data, to url: URL) throws -> URL {
    try bytes.write(to: url)
    return url
  }
}

/// A monotonic clock with a fixed step, so `lastUsedAt` orders entries deterministically instead
/// of depending on how fast the machine ran the test.
final class StepClock: @unchecked Sendable {
  private let lock = NSLock()
  private var step = 0

  func next() -> Date {
    lock.withLock {
      step += 1
      return Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(step))
    }
  }
}

/// Holds the *first* caller until `open()`, and lets every later caller straight through.
///
/// Injected as the cache's `pinned` closure, which every fetch awaits before it may evict
/// anything: that is the one place a test can park a fetch mid-flight without a network stub, a
/// sleep, or any dependence on timing.
actor FetchLatch {
  private var calls = 0
  private var held: [CheckedContinuation<Void, Never>] = []
  private var arrived: [CheckedContinuation<Void, Never>] = []
  private var isHeld = false
  private var opened = false

  var callCount: Int { calls }

  func passOrHold() async {
    calls += 1
    guard calls == 1, !opened else { return }
    await withCheckedContinuation { continuation in
      held.append(continuation)
      isHeld = true
      for waiter in arrived { waiter.resume() }
      arrived = []
    }
  }

  func waitUntilHeld() async {
    guard !isHeld else { return }
    await withCheckedContinuation { arrived.append($0) }
  }

  func open() {
    opened = true
    for continuation in held { continuation.resume() }
    held = []
  }
}
