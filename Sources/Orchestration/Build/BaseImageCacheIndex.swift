import Foundation
import Logging
import Metrics
import RunnerCore

/// The on-disk half of `BaseImageCache`: file naming, atomic sidecar writes, the startup scan that
/// rebuilds the LRU index, and the sweep that removes everything a crashed fetch left behind.
extension BaseImageCache {
  static let prefix = "base-"
  static let rawSuffix = ".raw"
  static let sidecarSuffix = ".json"

  func rawURL(_ key: String) -> URL { directory.appending(path: "\(Self.prefix)\(key).raw") }
  func sidecarURL(_ key: String) -> URL { directory.appending(path: "\(Self.prefix)\(key).json") }
  func partURL(_ key: String) -> URL { directory.appending(path: "\(Self.prefix)\(key).part") }
  func rawPartURL(_ key: String) -> URL { directory.appending(path: "\(Self.prefix)\(key).raw.part") }
  func sidecarPartURL(_ key: String) -> URL {
    directory.appending(path: "\(Self.prefix)\(key).json.part")
  }

  // MARK: - Sidecar

  static func readSidecar(at url: URL) -> Sidecar? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Sidecar.self, from: data)
  }

  /// `.json.part` → rename, so a reader never sees a half-written sidecar and a torn write leaves
  /// the entry looking absent rather than looking valid.
  static func writeSidecar(_ sidecar: Sidecar, to url: URL) throws {
    let part = url.appendingPathExtension("part")
    try? FileManager.default.removeItem(at: part)
    try JSONEncoder().encode(sidecar).write(to: part)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: part, to: url)
  }

  // MARK: - Index

  /// Idempotent, and the scan itself never suspends: `indexed` flips before the first `await`, so
  /// a second fetch racing the first does not re-scan.
  func prepare() async {
    guard !indexed else { return }
    let swept = scan()
    if swept > 0 {
      await metrics?.increment(
        RunnerVMMetrics.imageCacheEvictionsTotal,
        labels: [RunnerVMMetrics.reasonLabel: "sweep"], by: Double(swept))
    }
    await publish()
  }

  /// Rebuilds the index from what is actually on disk and returns how many leftovers it removed.
  /// A valid entry is a raw disk plus a sidecar whose recorded size still matches it; anything
  /// else -- a `.part` from a killed transfer, a raw disk a crashed conversion never sidecar'd, a
  /// sidecar whose disk is gone -- is swept, because none of it can ever become a hit.
  private func scan() -> Int {
    indexed = true
    index = [:]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    var swept = 0
    for name in names.sorted() where name.hasPrefix(Self.prefix) {
      if name.hasSuffix(".part") {
        swept += sweep(name: name, reason: "interrupted transfer")
      } else if name.hasSuffix(Self.rawSuffix) {
        swept += adopt(rawNamed: name)
      } else if name.hasSuffix(Self.sidecarSuffix), !hasRaw(sidecarNamed: name) {
        swept += sweep(name: name, reason: "sidecar with no raw disk")
      }
    }
    return swept
  }

  private func adopt(rawNamed name: String) -> Int {
    let key = String(name.dropFirst(Self.prefix.count).dropLast(Self.rawSuffix.count))
    let raw = directory.appending(path: name)
    guard let meta = Self.readSidecar(at: sidecarURL(key)), Self.size(of: raw) == meta.virtualSize
    else {
      // Sidecar missing or stale: the bytes cannot be validated, so they are not an entry.
      try? FileManager.default.removeItem(at: sidecarURL(key))
      return sweep(name: name, reason: "raw disk with no usable sidecar")
    }
    index[key] = Entry(
      key: key, bytes: Self.allocatedSize(of: raw),
      lastUsedAt: meta.lastUsedAt ?? Self.modifiedAt(raw))
    return 0
  }

  private func hasRaw(sidecarNamed name: String) -> Bool {
    let key = String(name.dropFirst(Self.prefix.count).dropLast(Self.sidecarSuffix.count))
    return FileManager.default.fileExists(atPath: rawURL(key).path(percentEncoded: false))
  }

  private func sweep(name: String, reason: String) -> Int {
    let url = directory.appending(path: name)
    let bytes = Self.allocatedSize(of: url)
    guard (try? FileManager.default.removeItem(at: url)) != nil else { return 0 }
    logger.notice(
      "swept base image cache leftover",
      metadata: [
        "file": .string(name), "bytes": .stringConvertible(bytes), "reason": .string(reason),
      ])
    return 1
  }

  // MARK: - Metrics

  /// Republished wholesale after every index change, so a cache that shrank to nothing reports 0
  /// instead of freezing at its last non-empty value.
  func publish() async {
    guard let metrics else { return }
    await metrics.setGauge(RunnerVMMetrics.imageCacheBytes, to: Double(totalBytes))
    await metrics.setGauge(RunnerVMMetrics.imageCacheEntries, to: Double(index.count))
  }

  var totalBytes: UInt64 { index.values.reduce(UInt64(0)) { $0.addedOrMax($1.bytes) } }

  // MARK: - Sizes

  /// Logical size: what the sidecar records and what a hit re-validates against.
  static func size(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  /// Blocks the volume actually gave up, which is what the quota is written against: a converted
  /// cloud disk is sparse, and charging its 16 GiB logical size against `maxBytes` would evict
  /// entries that together occupy a fraction of that.
  static func allocatedSize(of url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    if let values = try? url.resourceValues(forKeys: keys),
       let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize, allocated > 0 {
      return UInt64(allocated)
    }
    return size(of: url)
  }

  static func modifiedAt(_ url: URL) -> Date {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
  }
}
