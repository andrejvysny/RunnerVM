import Foundation
import ImageStore
import Logging
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import RunnerLogging

/// One image as the daemon API reports it: the database row plus the footprint measured on disk.
public struct ManagedImage: Sendable, Equatable {
  public var record: ImageRecord
  public var allocatedBytes: UInt64
  public var pinCount: Int
  public var name: String?
  /// The image's own `metadata.json` as the store holds it; `nil` only when the manifest could not
  /// be read. `record.metadataJson` carries the same bytes, already encoded.
  public var metadata: ImageMetadata?
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
  /// Not `private`: `ImagePulling.swift` extends this actor from a separate file to keep this one
  /// under its line budget, and cross-file extensions cannot see `private` members.
  let store: ImageStore
  let images: any ImageRepository
  let instances: any InstanceRepository
  /// `nil` in callers that don't care about the "pending operation" prune rule (spec §110) or
  /// about tracking a pull as an operation.
  let operations: (any OperationRepository)?
  let architecture: String
  let paths: RunnerPaths
  let registries: any RegistryClientFactory
  let metrics: MetricRegistry
  let now: @Sendable () -> Date
  let logger: Logger

  /// One in-flight transfer per resolved manifest digest, however many callers asked for it
  /// (spec §137). Keyed by the *registry* manifest digest, which is what tag resolution produces
  /// and the only identity known before any bytes move.
  var inFlightPulls: [ImageDigest: InFlightPull] = [:]
  /// Staging directory names of pushes this process is running, so the sweep leaves them alone.
  var activePushStaging: Set<String> = []
  var activePullCount = 0
  /// Highest `activePullCount` this daemon has reached, so the concurrency gate is observable
  /// without instrumenting every transfer.
  var peakActivePulls = 0
  var pullWaiters: [CheckedContinuation<Void, Never>] = []
  var concurrentPulls = HostConfig.Limits().concurrentImagePulls
  var hostReserveDiskBytes = HostConfig.Reserve().diskBytes
  /// Tag → digest, so a profile that names a moving tag does not hit the registry on every
  /// `vm create`. Registry-qualified reference string → (digest, resolved at).
  var tagResolutions: [String: (digest: ImageDigest, at: Date)] = [:]

  /// How long a tag → digest resolution is trusted before the registry is asked again (spec §21:
  /// the digest is what gets pinned, the tag is only a lookup key).
  public static let tagResolutionTTL: Duration = .seconds(300)

  public init(
    store: ImageStore, images: any ImageRepository, instances: any InstanceRepository,
    operations: (any OperationRepository)? = nil, architecture: String, paths: RunnerPaths,
    registries: any RegistryClientFactory = DefaultRegistryClientFactory(
      credentials: ChainedRegistryCredentials.standard()),
    metrics: MetricRegistry = MetricRegistry(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .image)
  ) {
    self.store = store
    self.images = images
    self.instances = instances
    self.operations = operations
    self.architecture = architecture
    self.paths = paths
    self.registries = registries
    self.metrics = metrics
    self.now = now
    self.logger = logger
  }

  /// Picks up `host.limits.concurrentImagePulls` and the free-space floor a pull must respect.
  /// Called at bootstrap and on every `config.apply`.
  public func updateConfiguration(_ config: RunnerConfiguration?) {
    concurrentPulls = max(1, config?.host.limits.concurrentImagePulls
      ?? HostConfig.Limits().concurrentImagePulls)
    hostReserveDiskBytes = config?.host.reserve.diskBytes ?? HostConfig.Reserve().diskBytes
    // A raised limit must wake whoever is queued behind the old one.
    wakePullWaiters()
  }

  // MARK: - Import

  /// Imports a raw disk that already exists on this host. Idempotent by content: a second import
  /// of identical bytes updates the row and stores no second copy.
  ///
  /// A `metadata.json` sealed next to the disk -- or named explicitly with `metadataPath` -- is
  /// adopted whole, so `runnerVersion`, `guestAgentVersion`, `capabilities` and `provenance`
  /// survive the import instead of being re-synthesised (see `SealedImageMetadata.swift`).
  ///
  /// `guestAgent` records whether this disk carries a RunnerVM guest agent (`runnerctl image
  /// import --no-guest-agent` for one that does not, e.g. a build/inspection-only artifact).
  public func importLocal(
    disk: URL, nvram: URL?, os: GuestOS, name: String?, hardwareModel: String? = nil,
    metadataPath: URL? = nil, guestAgent: Bool = true
  ) async throws -> ManagedImage {
    let size = try Self.fileSize(at: disk)
    var metadata = try resolveImportMetadata(
      disk: disk, size: size, os: os, hardwareModel: hardwareModel, metadataPath: metadataPath)
    metadata.capabilities.guestAgent = Self.resolvedGuestAgent(
      requested: guestAgent, existing: metadata.capabilities.guestAgent)
    let imported = try await store.importLocal(
      disk: disk, nvram: nvram, metadata: metadata, name: name)
    let info = try await store.inspect(digest: imported.digest)
    let record = try makeRecord(info: info, directory: imported.manifestDirectory, name: name)
    try await images.upsert(record)
    // Last successful registration under a name wins: a rebuild-style re-import of the same local
    // name repoints the alias at the new digest instead of leaving `record(for:)` to guess between
    // two manifests that both happen to carry that name.
    if let name {
      try await images.setAlias(name: name, digest: record.digest)
    }
    logger.info(
      "image registered",
      metadata: .context(imageDigest: record.digest)
        .merging(["name": .string(name ?? "-"), "created": .stringConvertible(imported.created)]) { $1 })
    return ManagedImage(
      record: record, allocatedBytes: info.allocatedBytes, pinCount: 0,
      name: info.manifest.name ?? name, metadata: info.metadata)
  }

  /// `--no-guest-agent` (`requested == false`) always wins. Otherwise (the default `true`), an
  /// adopted sealed `metadata.json` that already recorded an explicit value keeps it -- an image
  /// deliberately sealed without an agent must not silently gain one just because the caller did
  /// not pass the flag -- and only a metadata with nothing recorded (synthesised, or a sealed file
  /// from before this field existed) is stamped `true`.
  private static func resolvedGuestAgent(requested: Bool, existing: Bool?) -> Bool {
    guard requested else { return false }
    return existing ?? true
  }

  func makeRecord(
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

  // MARK: - Reservations

  /// Resolves `reference`, inspects the blobs and pins the digest to `instanceId` under the
  /// `planning` owner -- all inside this actor, the same serialization point `prune` and `delete`
  /// run on. Both of those re-check `pinCount` immediately before touching a candidate's blobs
  /// (see `deleteCandidates`), so once this pin lands neither can delete the digest reserved here;
  /// `InstanceManager.create` calls this before the instance row exists, closing the window where
  /// a concurrent `image.prune` could otherwise delete an image mid-create.
  ///
  /// A registry-qualified `reference` is resolved -- and pulled, if this host has never seen the
  /// digest -- before the pin is taken, which is what makes the first `vm create` after a profile
  /// change slow (docs/images.md). Existing instances keep the digest they were created with.
  public func reserve(
    reference: String, for instanceId: InstanceID, profile: String? = nil
  ) async throws -> (ImageDigest, ImageInfo) {
    let digest = try await resolveRecord(
      reference: reference, profile: profile, purpose: .instance).digest
    let info = try await store.inspect(digest: digest)
    // Before the pin, not after: an image that can never run a job must not leave a `planning`
    // pin behind for the caller to clean up, and a locally cached agentless image (spec §58)
    // never went through the remote refusal in `resolveRecord`.
    guard info.metadata.hasGuestAgent else {
      throw ImageError.noGuestAgent(digest: digest, reference: reference)
    }
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


  func decorate(_ record: ImageRecord) async throws -> ManagedImage {
    // `name` is the local label from the immutable manifest, which a later registry pull cannot
    // move; `canonicalReference` is the provenance, which it can.
    let info = try? await store.inspect(digest: record.digest)
    return ManagedImage(
      record: record,
      allocatedBytes: info?.allocatedBytes ?? record.allocatedSizeBytes ?? 0,
      pinCount: try await images.pinCount(digest: record.digest),
      name: info?.manifest.name ?? record.canonicalReference,
      metadata: info?.metadata)
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
    try await images.removeAliases(digest: digest)
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

  /// Drops abandoned `images/.tmp` staging directories, *except* the ones a pull is still using.
  ///
  /// Not `ImageStore.sweepStaging`: a resumable pull (spec §119) keeps writing into one directory
  /// for as long as the transfer takes, and a directory's mtime does not move while a file inside
  /// it is appended to -- so an hour-long pull looks stale to a plain age sweep. A pull is
  /// protected while this process holds it in flight, and, across a daemon restart, while its
  /// `pull-image` operation row is still `running`.
  public func sweepStaging(olderThan retention: Duration, now: Date = Date()) async throws -> Int {
    let protected = try await protectedStagingNames()
    let manager = FileManager.default
    let root = stagingRoot
    guard manager.fileExists(atPath: root.path(percentEncoded: false)) else { return 0 }
    let cutoff = now.addingTimeInterval(-Self.seconds(retention))
    var removed = 0
    for child in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    where !protected.contains(child.lastPathComponent) {
      let attributes = try? manager.attributesOfItem(atPath: child.path(percentEncoded: false))
      guard let modified = attributes?[.modificationDate] as? Date, modified < cutoff else { continue }
      try manager.removeItem(at: child)
      removed += 1
    }
    return removed
  }

  var stagingRoot: URL {
    paths.imagesDir.appending(path: ".tmp", directoryHint: .isDirectory)
  }

  private func protectedStagingNames() async throws -> Set<String> {
    var names = activePushStaging
    for digest in inFlightPulls.keys { names.insert(Self.pullStagingName(for: digest)) }
    guard let operations else { return names }
    for row in try await operations.list(state: .running) where row.kind == Self.pullOperationKind {
      names.insert(Self.pullStagingName(for: ImageDigest(rawValue: row.resourceId)))
    }
    return names
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
    let swept = try await sweepStaging(olderThan: .seconds(3_600), now: now)
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
