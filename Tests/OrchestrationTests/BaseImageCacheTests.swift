import Foundation
import Metrics
import RunnerCore
import Testing

@testable import Orchestration

/// The bounded `FROM cloud-image:` base cache: LRU eviction, pins that outrank the quota, atomic
/// commit, the host free-space floor, and the gauges/counters that make all of it observable.
@Suite struct BaseImageCacheTests {
  private static func withFixture(
    _ body: (BaseImageCacheFixture) async throws -> Void
  ) async throws {
    let fixture = try BaseImageCacheFixture()
    defer { fixture.cleanUp() }
    try await body(fixture)
  }

  // MARK: - Quotas

  /// Three bases, room for two: the one whose `lastUsedAt` is oldest goes, and a cache *hit* is
  /// what moves an entry to the front of that order.
  @Test func theBytesQuotaEvictsTheLeastRecentlyUsedBase() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let c = try fixture.source("c", fill: 0xC3)
      let metrics = MetricRegistry()
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(maxBytes: 3 * fixture.unit, minimumHostFreeBytes: 0),
        metrics: metrics)

      _ = try await cache.fetch(location: a.path, sha256: a.digest, noCache: false)
      _ = try await cache.fetch(location: b.path, sha256: b.digest, noCache: false)
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 2)
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheBytes) == Double(2 * fixture.unit))

      // Re-reads `a`, which makes `b` the least recently used even though it landed second.
      let hit = try await cache.fetch(location: a.path, sha256: a.digest, noCache: false)
      #expect(hit.cacheHit)

      _ = try await cache.fetch(location: c.path, sha256: c.digest, noCache: false)
      #expect(fixture.hasEntry(a))
      #expect(!fixture.hasEntry(b))
      #expect(fixture.hasEntry(c))
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 2)
      #expect(
        await metrics.counter(
          name: RunnerVMMetrics.imageCacheEvictionsTotal,
          labels: [RunnerVMMetrics.reasonLabel: "bytes"]) == 1)
    }
  }

  @Test func theEntryQuotaEvictsTheLeastRecentlyUsedBase() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let c = try fixture.source("c", fill: 0xC3)
      let metrics = MetricRegistry()
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0, maxEntries: 2), metrics: metrics)

      for source in [a, b, c] {
        _ = try await cache.fetch(location: source.path, sha256: source.digest, noCache: false)
      }
      #expect(!fixture.hasEntry(a))
      #expect(fixture.hasEntry(b))
      #expect(fixture.hasEntry(c))
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 2)
      #expect(
        await metrics.counter(
          name: RunnerVMMetrics.imageCacheEvictionsTotal,
          labels: [RunnerVMMetrics.reasonLabel: "entries"]) == 1)
    }
  }

  /// A base a live build row still depends on outranks the quota: the *new* fetch is refused, and
  /// nothing already on disk is touched.
  @Test func aPinnedBaseIsRefusedRatherThanEvicted() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let metrics = MetricRegistry()
      let pinnedKey = a.key
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0, maxEntries: 1),
        pinned: { [pinnedKey] }, metrics: metrics)

      _ = try await cache.fetch(location: a.path, sha256: a.digest, noCache: false)
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await cache.fetch(location: b.path, sha256: b.digest, noCache: false)
      }
      let code = try #require(error).code
      #expect(code == "BUILD_INSUFFICIENT_DISK")
      #expect(fixture.hasEntry(a))
      #expect(!fixture.hasEntry(b))
      #expect(fixture.files == ["base-\(a.key).json", "base-\(a.key).raw"])
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 1)
      #expect(await metrics.counter(name: RunnerVMMetrics.imageCacheEvictionsTotal) == 0)
    }
  }

  // MARK: - Concurrency

  /// A base being re-fetched right now is as unevictable as a pinned one: the concurrent fetch of
  /// a different digest is refused instead of pulling the running one's bytes out from under it.
  @Test func anInFlightBaseIsNotEvictedByAConcurrentFetch() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let seed = fixture.cache(policy: BaseImageCachePolicy(minimumHostFreeBytes: 0))
      _ = try await seed.fetch(location: a.path, sha256: a.digest, noCache: false)

      let latch = FetchLatch()
      let metrics = MetricRegistry()
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0, maxEntries: 1),
        pinned: { await latch.passOrHold(); return [] }, metrics: metrics)

      let refetch = Task { try await cache.fetch(location: a.path, sha256: a.digest, noCache: true) }
      await latch.waitUntilHeld()

      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await cache.fetch(location: b.path, sha256: b.digest, noCache: false)
      }
      let code = try #require(error).code
      #expect(code == "BUILD_INSUFFICIENT_DISK")
      #expect(fixture.hasEntry(a))
      #expect(await metrics.counter(name: RunnerVMMetrics.imageCacheEvictionsTotal) == 0)

      await latch.open()
      let refetched = try await refetch.value
      #expect(!refetched.cacheHit)
      #expect(fixture.hasEntry(a))
    }
  }

  /// Two builds naming the same digest cost one transfer, not two.
  @Test func concurrentFetchesOfTheSameDigestShareOneTransfer() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let latch = FetchLatch()
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0),
        pinned: { await latch.passOrHold(); return [] })

      let first = Task { try await cache.fetch(location: a.path, sha256: a.digest, noCache: false) }
      await latch.waitUntilHeld()
      let second = Task { try await cache.fetch(location: a.path, sha256: a.digest, noCache: false) }
      // Give the second caller room to reach the in-flight map before the first is released; the
      // assertion below holds either way, this only makes the case it is testing the likely one.
      for _ in 0..<10 {
        await Task.yield()
      }
      await latch.open()

      let one = try await first.value
      let two = try await second.value
      #expect(one.raw == two.raw)
      #expect(one.rawSHA256 == two.rawSHA256)
      let transfers = await cache.transferCount
      #expect(transfers == 1)
      #expect(fixture.hasEntry(a))
    }
  }

  // MARK: - Failure paths

  @Test func anUnreadableSourceLeavesNoEntryAndNoPartials() async throws {
    try await Self.withFixture { fixture in
      let metrics = MetricRegistry()
      let cache = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0), metrics: metrics)
      let missing = fixture.root.appending(path: "absent.img").path(percentEncoded: false)
      let digest = "sha256:" + String(repeating: "d", count: 64)

      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await cache.fetch(location: missing, sha256: digest, noCache: false)
      }
      let code = try #require(error).code
      #expect(code == "BUILD_CONTEXT_UNREADABLE")
      #expect(fixture.files.isEmpty)
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 0)
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheBytes) == 0)
    }
  }

  @Test func aDigestMismatchLeavesNoEntry() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let cache = fixture.cache(policy: BaseImageCachePolicy(minimumHostFreeBytes: 0))

      let error = await #expect(throws: ImageBuildError.self) {
        // `a`'s bytes announced under `b`'s digest: verified before anything is converted.
        _ = try await cache.fetch(location: a.path, sha256: b.digest, noCache: false)
      }
      let code = try #require(error).code
      #expect(code == "BUILD_BASE_DIGEST_MISMATCH")
      #expect(fixture.files.isEmpty)
    }
  }

  // MARK: - Restart

  /// A new actor over the same directory rebuilds the index -- including the LRU order -- from the
  /// sidecars, and removes every partial a killed process could have left.
  @Test func aRestartRebuildsTheIndexAndSweepsLeftovers() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let c = try fixture.source("c", fill: 0xC3)
      let seed = fixture.cache(policy: BaseImageCachePolicy(minimumHostFreeBytes: 0))
      _ = try await seed.fetch(location: a.path, sha256: a.digest, noCache: false)
      _ = try await seed.fetch(location: b.path, sha256: b.digest, noCache: false)

      let stampA = try #require(fixture.sidecar(a)?.lastUsedAt)
      let stampB = try #require(fixture.sidecar(b)?.lastUsedAt)
      #expect(stampA < stampB)

      let orphan = String(repeating: "e", count: 64)
      try fixture.plant("base-\(orphan).part")
      try fixture.plant("base-\(orphan).raw.part")
      try fixture.plant("base-\(orphan).json.part")
      try fixture.plant("base-\(orphan).raw")

      let metrics = MetricRegistry()
      let restarted = fixture.cache(
        policy: BaseImageCachePolicy(minimumHostFreeBytes: 0, maxEntries: 2), metrics: metrics)
      _ = try await restarted.fetch(location: c.path, sha256: c.digest, noCache: false)

      #expect(fixture.files == [
        "base-\(b.key).json", "base-\(b.key).raw", "base-\(c.key).json", "base-\(c.key).raw",
      ].sorted())
      // `a` went, not `b`: the restart read the LRU order back out of the sidecars.
      #expect(!fixture.hasEntry(a))
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 2)
      #expect(
        await metrics.counter(
          name: RunnerVMMetrics.imageCacheEvictionsTotal,
          labels: [RunnerVMMetrics.reasonLabel: "sweep"]) == 4)
    }
  }

  // MARK: - Free-space floor

  /// The floor evicts what it may and then refuses: an unpinned entry is fair game, a pinned one
  /// never is, and no partial download survives the refusal.
  @Test func theFreeSpaceFloorEvictsWhatItCanAndThenRefuses() async throws {
    try await Self.withFixture { fixture in
      let a = try fixture.source("a", fill: 0xA1)
      let b = try fixture.source("b", fill: 0xB2)
      let c = try fixture.source("c", fill: 0xC3)
      let metrics = MetricRegistry()
      // 2 units are walled off (1 host reserve + 1 cache floor), leaving three and a half for the
      // cache: room for two entries, but not while a third -- which needs its artifact and its
      // conversion side by side -- is being fetched.
      let capacity = 5 * fixture.unit + fixture.unit / 2
      let policy = BaseImageCachePolicy(minimumHostFreeBytes: fixture.unit)
      let cache = fixture.cache(
        policy: policy, capacity: capacity, reserveBytes: fixture.unit, metrics: metrics)

      for source in [a, b, c] {
        _ = try await cache.fetch(location: source.path, sha256: source.digest, noCache: false)
      }
      #expect(!fixture.hasEntry(a))
      #expect(fixture.hasEntry(b))
      #expect(fixture.hasEntry(c))
      #expect(
        await metrics.counter(
          name: RunnerVMMetrics.imageCacheEvictionsTotal,
          labels: [RunnerVMMetrics.reasonLabel: "reserve"]) == 1)

      // Pin what is left: with nothing evictable the next fetch fails closed rather than dipping
      // below the floor, and leaves no partial behind.
      let pins: Set<String> = [b.key, c.key]
      let pinnedCache = fixture.cache(
        policy: policy, capacity: capacity, reserveBytes: fixture.unit,
        pinned: { pins }, metrics: metrics)
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await pinnedCache.fetch(location: a.path, sha256: a.digest, noCache: false)
      }
      let code = try #require(error).code
      #expect(code == "BUILD_INSUFFICIENT_DISK")
      #expect(fixture.files == [
        "base-\(b.key).json", "base-\(b.key).raw", "base-\(c.key).json", "base-\(c.key).raw",
      ].sorted())
      #expect(await metrics.gauge(name: RunnerVMMetrics.imageCacheEntries) == 2)
    }
  }
}
