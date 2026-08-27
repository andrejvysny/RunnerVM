import Foundation
import Logging
import Metrics
import RunnerCore

/// The bounding half of `BaseImageCache`: which entries may go, in what order, and when a fetch
/// has to be refused instead.
extension BaseImageCache {
  /// Why an entry was evicted. Doubles as the `reason` label on
  /// `runnervm_image_cache_evictions_total`, so the constraint actually binding on a host is
  /// visible without reading the log.
  enum Bound: String, Sendable {
    case bytes
    case entries
    case reserve
  }

  /// What the cache would look like after a given number of evictions. Carried explicitly rather
  /// than re-read from the filesystem on every step: one pass must reach a fixed point even while
  /// something else is writing to the same volume.
  struct Projection: Sendable {
    var bytes: UInt64
    var entries: Int
    var available: UInt64
    /// 1 while a not-yet-present key is about to be added, 0 otherwise.
    var arriving: Int

    mutating func evicting(_ entry: BaseImageCache.Entry) {
      bytes = bytes > entry.bytes ? bytes - entry.bytes : 0
      entries -= 1
      available = available.addedOrMax(entry.bytes)
    }
  }

  /// Makes room for a fetch that has not started yet.
  ///
  /// Fails closed: if the bounds cannot hold even after evicting every unpinned entry, nothing is
  /// evicted and nothing is downloaded. Deleting a usable base only to refuse the fetch anyway
  /// would be the worst of both.
  func makeRoom(needed: UInt64, arriving key: String) async throws {
    let candidates = await evictable(excluding: key)
    var best = projection(arriving: index[key] == nil ? 1 : 0)
    let headroom = candidates.reduce(UInt64(0)) { $0.addedOrMax($1.bytes) }
    for candidate in candidates { best.evicting(candidate) }
    if let unmet = Self.violated(needed: needed, in: best, policy: policy) {
      logger.warning(
        "base image cache cannot make room for a base image",
        metadata: [
          "bound": .string(unmet.rawValue), "needed": .stringConvertible(needed),
          "evictable_bytes": .stringConvertible(headroom),
          "entries": .stringConvertible(index.count),
        ])
      throw ImageBuildError.insufficientDisk(
        needed: needed, free: availableBytes().addedOrMax(headroom))
    }
    await evict(candidates, needed: needed, from: projection(arriving: best.arriving))
  }

  /// Post-commit pass. Best-effort by design: the fetch already succeeded and its own entry is
  /// pinned for the duration, so an unmet bound here is a host to alert on, not a build to fail.
  func enforceQuotas() async {
    let candidates = await evictable(excluding: nil)
    await evict(candidates, needed: 0, from: projection(arriving: 0))
  }

  // MARK: - Internals

  private func projection(arriving: Int) -> Projection {
    Projection(
      bytes: totalBytes, entries: index.count, available: availableBytes(), arriving: arriving)
  }

  /// LRU order, oldest first; the key breaks ties so two entries stamped in the same instant are
  /// still evicted in a fixed order. Pinned and in-flight keys are never candidates -- refusing a
  /// fetch is always preferable to pulling a base out from under a running build.
  private func evictable(excluding key: String?) async -> [Entry] {
    var protected = Set(await pinned().map(Self.normalize))
    protected.formUnion(inFlight.keys)
    if let key { protected.insert(key) }
    return index.values
      .filter { !protected.contains($0.key) }
      .sorted { ($0.lastUsedAt, $0.key) < ($1.lastUsedAt, $1.key) }
  }

  private func evict(_ candidates: [Entry], needed: UInt64, from start: Projection) async {
    var projected = start
    var remaining = candidates[...]
    var evicted = false
    while let unmet = Self.violated(needed: needed, in: projected, policy: policy),
          let victim = remaining.popFirst() {
      remove(victim, bound: unmet)
      projected.evicting(victim)
      evicted = true
      await metrics?.increment(
        RunnerVMMetrics.imageCacheEvictionsTotal,
        labels: [RunnerVMMetrics.reasonLabel: unmet.rawValue])
    }
    if evicted { await publish() }
  }

  private func remove(_ entry: Entry, bound: Bound) {
    try? FileManager.default.removeItem(at: sidecarURL(entry.key))
    try? FileManager.default.removeItem(at: rawURL(entry.key))
    index[entry.key] = nil
    logger.info(
      "evicted cached base image",
      metadata: [
        "base_sha256": .string(entry.key), "bytes": .stringConvertible(entry.bytes),
        "reason": .string(bound.rawValue),
      ])
  }

  /// The first bound still broken in `projection`, or `nil` when all of them hold.
  static func violated(
    needed: UInt64, in projection: Projection, policy: BaseImageCachePolicy
  ) -> Bound? {
    if let maxBytes = policy.maxBytes, projection.bytes.addedOrMax(needed) > maxBytes {
      return .bytes
    }
    if let maxEntries = policy.maxEntries, projection.entries + projection.arriving > maxEntries {
      return .entries
    }
    // `available == 0` is refused even for a zero-byte estimate: an unknown `Content-Length` must
    // not be read as "this download is free".
    if projection.available == 0 || needed > projection.available { return .reserve }
    return nil
  }

  /// What the cache may use: the volume's free space less the host's own disk reserve and the
  /// cache's floor on top of it. Saturating, so a misconfigured floor refuses rather than wraps.
  func availableBytes() -> UInt64 {
    let free = freeSpaceProbe(directory)
    let floor = reserveBytes.addedOrMax(policy.minimumHostFreeBytes)
    return free > floor ? free - floor : 0
  }
}
