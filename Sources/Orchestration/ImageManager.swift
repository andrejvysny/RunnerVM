import Foundation
import ImageStore
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// One image as the daemon API reports it: the database row plus the footprint measured on disk.
public struct ManagedImage: Sendable, Equatable {
  public var record: ImageRecord
  public var allocatedBytes: UInt64
  public var pinCount: Int
  public var name: String?
}

/// One `image.prune` run (spec §110, §57): candidates, what was actually deleted (empty on a dry
/// run), pinned images that were never eligible, bytes reclaimed and stale `.tmp` entries swept.
public struct ImagePruneReport: Sendable, Equatable {
  public var candidates: [ImageDigest]
  public var deleted: [ImageDigest]
  public var keptPinned: [ImageDigest]
  public var reclaimedBytes: UInt64
  public var staleStagingRemoved: Int

  public init(
    candidates: [ImageDigest] = [], deleted: [ImageDigest] = [], keptPinned: [ImageDigest] = [],
    reclaimedBytes: UInt64 = 0, staleStagingRemoved: Int = 0
  ) {
    self.candidates = candidates
    self.deleted = deleted
    self.keptPinned = keptPinned
    self.reclaimedBytes = reclaimedBytes
    self.staleStagingRemoved = staleStagingRemoved
  }
}

/// Owns the local image catalogue: `ImageStore` holds the bytes, `ImageRepository` holds the rows
/// and the pins, and this actor keeps the two consistent.
public actor ImageManager {
  private let store: ImageStore
  private let images: any ImageRepository
  private let instances: any InstanceRepository
  /// `nil` in callers that don't care about the "pending operation" prune rule (spec §110); no
  /// production code creates an `image`-typed operation row yet, so this only changes behaviour
  /// once something does.
  private let operations: (any OperationRepository)?
  private let architecture: String
  private let logger: Logger

  public init(
    store: ImageStore, images: any ImageRepository, instances: any InstanceRepository,
    operations: (any OperationRepository)? = nil, architecture: String,
    logger: Logger = Logger(component: .image)
  ) {
    self.store = store
    self.images = images
    self.instances = instances
    self.operations = operations
    self.architecture = architecture
    self.logger = logger
  }

  // MARK: - Import

  /// Imports a raw disk that already exists on this host. Idempotent by content: a second import
  /// of identical bytes updates the row and stores no second copy.
  public func importLocal(
    disk: URL, nvram: URL?, os: GuestOS, name: String?, hardwareModel: String? = nil
  ) async throws -> ManagedImage {
    let size = try Self.fileSize(at: disk)
    let metadata = ImageMetadata(
      os: os,
      architecture: architecture,
      virtualDiskSizeBytes: size,
      createdAt: Date(),
      boot: ImageMetadata.Boot(type: os == .macos ? .macos : .efi),
      macos: hardwareModel.map { ImageMetadata.MacOSPlatform(hardwareModel: $0) })
    let imported = try await store.importLocal(
      disk: disk, nvram: nvram, metadata: metadata, name: name)
    let info = try await store.inspect(digest: imported.digest)
    let record = try makeRecord(info: info, directory: imported.manifestDirectory, name: name)
    try await images.upsert(record)
    logger.info(
      "image registered",
      metadata: .context(imageDigest: record.digest)
        .merging(["name": .string(name ?? "-"), "created": .stringConvertible(imported.created)]) { $1 })
    return ManagedImage(
      record: record, allocatedBytes: info.allocatedBytes, pinCount: 0,
      name: info.manifest.name ?? name)
  }

  private func makeRecord(
    info: ImageInfo, directory: URL, name: String?
  ) throws -> ImageRecord {
    let metadataJSON = String(
      decoding: try JSONEncoder.imageMetadata().encode(info.metadata), as: UTF8.self)
    return ImageRecord(
      digest: info.digest,
      canonicalReference: info.manifest.name ?? name,
      os: info.metadata.os,
      architecture: info.metadata.architecture,
      schemaVersion: info.metadata.schemaVersion,
      metadataJson: metadataJSON,
      localPath: directory.path(percentEncoded: false),
      virtualSizeBytes: info.virtualBytes,
      allocatedSizeBytes: info.allocatedBytes,
      runnerVersion: info.metadata.runnerVersion,
      guestAgentVersion: info.metadata.guestAgentVersion,
      state: .ready,
      createdAt: DatabaseDate(info.metadata.createdAt),
      pulledAt: .now)
  }

  // MARK: - Read

  public func list() async throws -> [ManagedImage] {
    var result: [ManagedImage] = []
    for record in try await images.list(state: nil).sorted(by: { $0.digest.rawValue < $1.digest.rawValue }) {
      result.append(try await decorate(record))
    }
    return result
  }

  /// `ref` is a `sha256:` digest or a local name (the label the image was imported under).
  public func get(reference: String) async throws -> ManagedImage {
    try await decorate(try await record(for: reference))
  }

  /// Profile `image:` values in v1 resolve locally only; registry references arrive in M9.
  public func resolve(reference: String) async throws -> ImageDigest {
    try await record(for: reference).digest
  }

  // MARK: - Reservations

  /// Resolves `reference`, inspects the blobs and pins the digest to `instanceId` under the
  /// `planning` owner -- all inside this actor, the same serialization point `prune` and `delete`
  /// run on. Both of those re-check `pinCount` immediately before touching a candidate's blobs
  /// (see `deleteCandidates`), so once this pin lands neither can delete the digest reserved here;
  /// `InstanceManager.create` calls this before the instance row exists, closing the window where
  /// a concurrent `image.prune` could otherwise delete an image mid-create.
  public func reserve(
    reference: String, for instanceId: InstanceID
  ) async throws -> (ImageDigest, ImageInfo) {
    let digest = try await record(for: reference).digest
    let info = try await store.inspect(digest: digest)
    try await images.pin(ownerType: .planning, ownerId: instanceId.rawValue, digest: digest)
    return (digest, info)
  }

  /// Drops the `planning` pin for one instance: the reservation never became an instance row
  /// (admission was rejected, validation failed, or the daemon crashed before `instances.insert`).
  /// Idempotent -- safe to call even if no such pin exists.
  public func release(planning instanceId: InstanceID) async throws {
    try await images.unpinOwner(ownerType: .planning, ownerId: instanceId.rawValue)
  }

  /// Startup safety net: a crash between `reserve` and `instances.insert` leaves a `planning` pin
  /// with no instance row behind it, which would hold the image hostage forever. Call once at
  /// daemon start, after reconciliation has the full set of known instance ids.
  @discardableResult
  public func sweepStalePlanningPins(knownInstanceIDs: Set<InstanceID>) async throws -> Int {
    let orphaned = try await images.pins(ownerType: .planning)
      .filter { !knownInstanceIDs.contains(InstanceID(rawValue: $0.ownerId)) }
    for pin in orphaned {
      try await images.unpin(ownerType: .planning, ownerId: pin.ownerId, digest: pin.digest)
    }
    return orphaned.count
  }

  private func record(for reference: String) async throws -> ImageRecord {
    if reference.hasPrefix("sha256:"),
       let found = try await images.get(digest: ImageDigest(rawValue: reference)) {
      return found
    }
    let all = try await images.list(state: nil)
    if let named = all.first(where: { $0.canonicalReference == reference }) {
      return named
    }
    throw ImageError.notFound(
      reference: "\(reference) (v1 resolves local images only; import one with "
        + "`runnerctl image import <disk> --name \(reference)`)")
  }

  private func decorate(_ record: ImageRecord) async throws -> ManagedImage {
    let allocated = (try? await store.inspect(digest: record.digest).allocatedBytes)
      ?? record.allocatedSizeBytes ?? 0
    return ManagedImage(
      record: record, allocatedBytes: allocated,
      pinCount: try await images.pinCount(digest: record.digest),
      name: record.canonicalReference)
  }

  // MARK: - Delete

  /// Refuses while any pin or any live instance still references the image (plan C1 "Image GC").
  ///
  /// Order matters: the row goes before the bytes. A crash in between leaves blobs that
  /// `ImageStore.unreferencedBlobs()` reclaims, whereas deleting the bytes first would leave a row
  /// pointing at a manifest that is no longer there.
  public func delete(digest: ImageDigest) async throws {
    guard let record = try await images.get(digest: digest) else {
      throw ImageError.notFound(reference: digest.rawValue)
    }
    guard try await images.pinCount(digest: digest) == 0 else {
      throw ImageError.stillPinned(digest: digest)
    }
    let users = try await instances.list(profile: nil, states: nil)
      .filter { $0.imageDigest == digest && $0.state != .deleted }
    guard users.isEmpty else { throw ImageError.stillPinned(digest: digest) }

    if record.state != .deleting {
      try await images.setState(digest: digest, from: record.state, to: .deleting)
    }
    let purged = try await instances.purgeDeleted(imageDigest: digest)
    try await images.delete(digest: digest)
    try await store.delete(digest: digest)
    logger.info(
      "image deleted",
      metadata: .context(imageDigest: digest)
        .merging(["purged_instances": .stringConvertible(purged)]) { $1 })
  }

  // MARK: - Prune

  /// Reference-safe GC (spec §110): a candidate has no pin, no live instance and no pending
  /// operation pointing at it -- tags alone are never enough ("tags are not references").
  ///
  /// Running inside this actor is the barrier the cache spec asks for (spec §57 "acquire an
  /// image-store lock/reconciliation barrier") against `ImageManager`'s own writers (import,
  /// delete). It does not reach across into `InstanceManager`, which pins and inserts the
  /// instance row in two separate writes rather than one transaction (see
  /// `InstanceManager.create`), so each deletion below re-validates through `delete(digest:)` at
  /// the moment it happens instead of trusting the snapshot taken here.
  public func prune(
    policy: ImageCacheConfig, dryRun: Bool, now: Date = Date()
  ) async throws -> ImagePruneReport {
    let all = try await images.list(state: nil)
    let pinnedDigests = Set(all.map(\.digest))
      .subtracting(Set(try await images.unpinnedImages().map(\.digest)))
    let liveDigests = try await liveInstanceDigests()
    let pendingDigests = try await pendingOperationDigests()
    let ineligible = pinnedDigests.union(liveDigests).union(pendingDigests)
    let eligible = all.filter { !ineligible.contains($0.digest) }

    var picked = Set(staleCandidates(eligible, policy: policy, now: now))
    if let ceiling = policy.maxSizeBytes {
      let extra = try await sizeCandidates(all: all, eligible: eligible, ceiling: ceiling, picked: picked)
      picked.formUnion(extra)
    }
    let candidates = eligible.filter { picked.contains($0.digest) }.map(\.digest)

    var deleted: [ImageDigest] = []
    var reclaimedBytes: UInt64 = 0
    if !dryRun {
      (deleted, reclaimedBytes) = try await deleteCandidates(candidates)
    }
    let staleStagingRemoved = dryRun ? 0 : try await sweepStagingAndOrphanBlobs(now: now)
    return ImagePruneReport(
      candidates: candidates, deleted: deleted,
      keptPinned: pinnedDigests.sorted { $0.rawValue < $1.rawValue },
      reclaimedBytes: reclaimedBytes, staleStagingRemoved: staleStagingRemoved)
  }

  /// Passthrough so callers that only want the staging sweep (the periodic maintenance tick)
  /// don't need to reach into `ImageStore` directly.
  public func sweepStaging(olderThan retention: Duration, now: Date = Date()) async throws -> Int {
    try await store.sweepStaging(olderThan: retention, now: now)
  }

  private func liveInstanceDigests() async throws -> Set<ImageDigest> {
    Set(
      try await instances.list(profile: nil, states: nil)
        .filter { $0.state != .deleted }
        .map(\.imageDigest))
  }

  /// Operations in flight or still queued against an image reference. No production path creates
  /// one of these yet (spec §110's rule is otherwise unenforceable today), but the check is cheap
  /// and keeps prune correct once one does.
  private func pendingOperationDigests() async throws -> Set<ImageDigest> {
    guard let operations else { return [] }
    let rows = try await operations.list(state: nil)
    return Set(
      rows.filter { $0.resourceType == "image" && ($0.state == .pending || $0.state == .running) }
        .map { ImageDigest(rawValue: $0.resourceId) })
  }

  private func staleCandidates(
    _ eligible: [ImageRecord], policy: ImageCacheConfig, now: Date
  ) -> [ImageDigest] {
    let cutoff = now.addingTimeInterval(-Double(policy.keepRecentlyUsed.seconds))
    return eligible.filter { staleness($0) < cutoff }.map(\.digest)
  }

  /// LRU eviction toward `maxSizeBytes` (spec §110): the whole store's measured footprint decides
  /// whether the budget is exceeded, but only already-eligible (unpinned, unreferenced) images pay
  /// for it, oldest `staleness` first -- even ones still inside the retention window.
  private func sizeCandidates(
    all: [ImageRecord], eligible: [ImageRecord], ceiling: UInt64, picked: Set<ImageDigest>
  ) async throws -> [ImageDigest] {
    var total: UInt64 = 0
    for record in all { total += try await measuredBytes(record) }
    guard total > ceiling else { return [] }
    var extra: [ImageDigest] = []
    for record in eligible.sorted(by: { staleness($0) < staleness($1) })
    where !picked.contains(record.digest) {
      guard total > ceiling else { break }
      total -= try await measuredBytes(record)
      extra.append(record.digest)
    }
    return extra
  }

  /// Deletes through `delete(digest:)`, reusing the pin/instance check it already performs rather
  /// than trusting the snapshot above, so a reference that appeared after this prune started
  /// (spec §57 "never deletes blobs required by an active image/instance") is honoured. Losing
  /// that race is not a prune failure -- the image is simply left for next time.
  private func deleteCandidates(_ candidates: [ImageDigest]) async throws -> ([ImageDigest], UInt64) {
    var deleted: [ImageDigest] = []
    var reclaimedBytes: UInt64 = 0
    for digest in candidates {
      guard let bytes = try? await store.inspect(digest: digest).allocatedBytes else { continue }
      do {
        try await delete(digest: digest)
        deleted.append(digest)
        reclaimedBytes += bytes
      } catch let error as ImageError {
        guard case .stillPinned = error else { throw error }
        continue
      }
    }
    return (deleted, reclaimedBytes)
  }

  private func sweepStagingAndOrphanBlobs(now: Date) async throws -> Int {
    let swept = try await store.sweepStaging(olderThan: .seconds(3_600), now: now)
    for blob in try await store.unreferencedBlobs() {
      try? FileManager.default.removeItem(at: blob)
    }
    return swept
  }

  private func measuredBytes(_ record: ImageRecord) async throws -> UInt64 {
    (try? await store.inspect(digest: record.digest).allocatedBytes) ?? record.allocatedSizeBytes ?? 0
  }

  private func staleness(_ record: ImageRecord) -> Date {
    record.lastUsedAt?.date ?? record.pulledAt?.date ?? record.createdAt.date
  }

  // MARK: - Helpers

  private static func fileSize(at url: URL) throws -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: url.path(percentEncoded: false))
    guard let size = (attributes?[.size] as? NSNumber)?.uint64Value else {
      throw ImageError.notFound(reference: url.path(percentEncoded: false))
    }
    return size
  }
}

extension JSONEncoder {
  /// Same settings `ImageStore` writes `metadata.json` with, so `images.metadata_json` and the
  /// file on disk stay byte-comparable.
  static func imageMetadata() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
