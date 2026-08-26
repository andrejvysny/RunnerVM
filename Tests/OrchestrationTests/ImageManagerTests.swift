import Foundation
import ImageStore
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Prune fixture helpers. Distinct byte lengths are load-bearing: `importLinuxImage()` always
/// imports the exact same bytes, and import is idempotent by content, so tests that need several
/// independent digests import distinctly-sized files instead.
extension ImageManagerTests {
  fileprivate func importSized(_ harness: M2Harness, name: String, bytes: UInt64) async throws -> ManagedImage {
    let disk = try harness.sparseFile(named: "\(name).img", bytes: bytes)
    return try await harness.images.importLocal(disk: disk, nvram: nil, os: .linux, name: name)
  }

  /// Rewrites `pulled_at`/`created_at` directly in the row, bypassing the clock, so staleness and
  /// LRU order in a prune test don't depend on real sleeps between imports.
  fileprivate func backdate(_ harness: M2Harness, _ digest: ImageDigest, to date: Date) async throws {
    guard var record = try await harness.imageRows.get(digest: digest) else {
      Issue.record("no row for \(digest)")
      return
    }
    record.pulledAt = DatabaseDate(date)
    record.createdAt = DatabaseDate(date)
    try await harness.imageRows.upsert(record)
  }
}

@Suite struct ImageManagerTests {
  @Test func importRegistersARowAndIsIdempotentByContent() async throws {
    try await withHarness { harness in
      let first = try await harness.importLinuxImage()
      let second = try await harness.importLinuxImage()

      #expect(first.record.digest == second.record.digest)
      #expect(first.record.state == .ready)
      #expect(first.record.os == .linux)
      #expect(first.record.virtualSizeBytes == 32 << 20)
      #expect(try await harness.images.list().count == 1)
    }
  }

  @Test func imagesResolveByNameAndByDigest() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()

      #expect(try await harness.images.resolve(reference: M2Harness.linuxImageName)
        == image.record.digest)
      #expect(try await harness.images.resolve(reference: image.record.digest.rawValue)
        == image.record.digest)
    }
  }

  /// Since M9 a registry-qualified reference is resolved against the registry, so the failure is
  /// the registry's own -- not a local catalogue miss.
  @Test func aRegistryReferenceIsResolvedAgainstTheRegistry() async throws {
    try await withHarness { harness in
      let error = await #expect(throws: RegistryError.self) {
        _ = try await harness.images.resolve(reference: "ghcr.io/acme/ubuntu:24.04")
      }
      #expect(error?.code == "REGISTRY_NOT_FOUND")
    }
  }

  /// A bare name is still local-only, and the error has to say how to create one.
  @Test func anUnknownLocalNameSaysHowToImportOne() async throws {
    try await withHarness { harness in
      let error = await #expect(throws: ImageError.self) {
        _ = try await harness.images.resolve(reference: "not-imported")
      }
      #expect(error?.code == "IMAGE_NOT_FOUND")
      #expect(error?.message.contains("image import") == true)
    }
  }

  @Test func deleteRemovesTheBlobsAndTheRow() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()

      try await harness.images.delete(digest: image.record.digest)

      #expect(try await harness.images.list().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: image.record.localPath))
    }
  }

  @Test func deleteIsRefusedWhileAnInstancePinsTheImage() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      _ = try await harness.instances.create(profileName: "linux")

      let error = await #expect(throws: ImageError.self) {
        try await harness.images.delete(digest: image.record.digest)
      }
      #expect(error?.code == "IMAGE_STILL_PINNED")
      #expect(try await harness.images.list().count == 1)
    }
  }

  /// `instances.image_digest` is a foreign key, so the tombstone left by a deleted instance would
  /// otherwise block image GC forever.
  @Test func deleteSucceedsAfterTheInstanceUsingItWasDeleted() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      _ = try await harness.instances.delete(id: record.id)

      try await harness.images.delete(digest: image.record.digest)

      #expect(try await harness.images.list().isEmpty)
      #expect(try await harness.instanceRows.get(id: record.id) == nil)
    }
  }

  @Test func deletingAnUnknownImageIsNotFound() async throws {
    try await withHarness { harness in
      let error = await #expect(throws: ImageError.self) {
        try await harness.images.delete(
          digest: ImageDigest(rawValue: "sha256:" + String(repeating: "b", count: 64)))
      }
      #expect(error?.code == "IMAGE_NOT_FOUND")
    }
  }

  // MARK: - prune

  @Test func pruneDeletesAStaleUnpinnedImageButKeepsAPinnedOneAndARecentOne() async throws {
    try await withHarness { harness in
      let stale = try await importSized(harness, name: "stale", bytes: 32 << 20)
      let pinned = try await importSized(harness, name: "pinned", bytes: 33 << 20)
      let recent = try await importSized(harness, name: "recent", bytes: 34 << 20)
      try await backdate(harness, stale.record.digest, to: Date().addingTimeInterval(-10 * 86_400))
      try await backdate(harness, pinned.record.digest, to: Date().addingTimeInterval(-10 * 86_400))
      try await harness.imageRows.pin(
        ownerType: .profile, ownerId: "manual-pin", digest: pinned.record.digest)

      let report = try await harness.images.prune(
        policy: ImageCacheConfig(keepRecentlyUsed: .days(7)), dryRun: false)

      #expect(report.candidates == [stale.record.digest])
      #expect(report.deleted == [stale.record.digest])
      #expect(report.keptPinned == [pinned.record.digest])
      #expect(report.reclaimedBytes > 0)
      let remaining = Set(try await harness.images.list().map(\.record.digest))
      #expect(remaining == [pinned.record.digest, recent.record.digest])
    }
  }

  @Test func pruneKeepsAnImageStillReferencedByALiveInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      let report = try await harness.images.prune(
        policy: ImageCacheConfig(keepRecentlyUsed: .seconds(-1)), dryRun: false)

      #expect(report.candidates.isEmpty)
      #expect(try await harness.instanceRows.get(id: record.id) != nil)
      #expect(try await harness.images.list().count == 1)
    }
  }

  @Test func pruneDryRunReportsCandidatesButDeletesNothing() async throws {
    try await withHarness { harness in
      let stale = try await importSized(harness, name: "dry-stale", bytes: 32 << 20)
      try await backdate(harness, stale.record.digest, to: Date().addingTimeInterval(-10 * 86_400))

      let report = try await harness.images.prune(
        policy: ImageCacheConfig(keepRecentlyUsed: .days(7)), dryRun: true)

      #expect(report.candidates == [stale.record.digest])
      #expect(report.deleted.isEmpty)
      #expect(report.reclaimedBytes == 0)
      #expect(report.staleStagingRemoved == 0)
      #expect(try await harness.images.list().count == 1)
    }
  }

  /// `maxSizeBytes` evicts the least-recently-used unpinned image even though it is inside the
  /// retention window -- `keepRecentlyUsed` is set far in the future so only the size rule fires.
  @Test func pruneEvictsLeastRecentlyUsedImagesUnderMaxSizeBytes() async throws {
    try await withHarness { harness in
      let old = try await importSized(harness, name: "size-old", bytes: 32 << 20)
      let mid = try await importSized(harness, name: "size-mid", bytes: 33 << 20)
      let new = try await importSized(harness, name: "size-new", bytes: 34 << 20)
      let base = Date()
      try await backdate(harness, old.record.digest, to: base.addingTimeInterval(-3 * 3_600))
      try await backdate(harness, mid.record.digest, to: base.addingTimeInterval(-2 * 3_600))
      try await backdate(harness, new.record.digest, to: base.addingTimeInterval(-1 * 3_600))

      let oldBytes = try await harness.images.get(reference: old.record.digest.rawValue).allocatedBytes
      let midBytes = try await harness.images.get(reference: mid.record.digest.rawValue).allocatedBytes
      let newBytes = try await harness.images.get(reference: new.record.digest.rawValue).allocatedBytes

      let policy = ImageCacheConfig(maxSizeBytes: midBytes + newBytes, keepRecentlyUsed: .days(9_999))
      let report = try await harness.images.prune(policy: policy, dryRun: false)

      #expect(report.deleted == [old.record.digest])
      #expect(report.reclaimedBytes == oldBytes)
      let remaining = Set(try await harness.images.list().map(\.record.digest))
      #expect(remaining == [mid.record.digest, new.record.digest])
    }
  }

  @Test func pruneRemovesStaleStagingDirectoriesButNeverOnADryRun() async throws {
    try await withHarness { harness in
      let staging = harness.paths.imagesDir
        .appending(path: ".tmp", directoryHint: .isDirectory)
        .appending(path: "abandoned-import", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-2 * 3_600)],
        ofItemAtPath: staging.path(percentEncoded: false))
      let stagingPath = staging.path(percentEncoded: false)

      let dryRun = try await harness.images.prune(policy: ImageCacheConfig(), dryRun: true)
      #expect(dryRun.staleStagingRemoved == 0)
      #expect(FileManager.default.fileExists(atPath: stagingPath))

      let real = try await harness.images.prune(policy: ImageCacheConfig(), dryRun: false)
      #expect(real.staleStagingRemoved == 1)
      #expect(!FileManager.default.fileExists(atPath: stagingPath))
    }
  }

  /// No production path creates an `image`-typed operation row yet, so this wires a fresh
  /// `ImageManager` with the repository directly to exercise the rule spec §110 states.
  @Test func pruneKeepsAnImageWithAPendingOperation() async throws {
    try await withHarness { harness in
      let image = try await importSized(harness, name: "op-pending", bytes: 32 << 20)
      try await backdate(harness, image.record.digest, to: Date().addingTimeInterval(-10 * 86_400))
      let operations = GRDBOperationRepository(db: harness.database)
      _ = try await operations.start(
        kind: "test", resourceType: "image", resourceId: image.record.digest.rawValue,
        idempotencyKey: nil)
      let manager = ImageManager(
        store: harness.imageStore, images: harness.imageRows, instances: harness.instanceRows,
        operations: operations, architecture: "arm64", paths: harness.paths)

      let report = try await manager.prune(
        policy: ImageCacheConfig(keepRecentlyUsed: .days(7)), dryRun: false)

      #expect(report.candidates.isEmpty)
      #expect(try await harness.images.list().count == 1)
    }
  }

  // MARK: - reserve / planning pins

  /// The race this closes: `InstanceManager.create` used to resolve and inspect an image before
  /// any pin existed, so a `prune` landing in that window could delete it out from under a
  /// still-in-flight create. `reserve` now pins before returning, inside the same actor `prune`
  /// runs on, so an aggressive concurrent prune must still keep the reservation.
  @Test func pruneCannotDeleteAnImageReservedForAnInFlightCreate() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      let instanceId = InstanceID.generate()

      let (digest, info) = try await harness.images.reserve(
        reference: M2Harness.linuxImageName, for: instanceId)
      #expect(digest == image.record.digest)
      #expect(info.digest == digest)

      let report = try await harness.images.prune(
        policy: ImageCacheConfig(keepRecentlyUsed: .seconds(-1)), dryRun: false)
      #expect(report.deleted.isEmpty)
      #expect(try await harness.images.list().contains { $0.record.digest == digest })

      // The reservation now completes exactly as `InstanceManager.create` would.
      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .waitingForAgent)
      try await harness.images.release(planning: instanceId)
    }
  }

  @Test func sweepStalePlanningPinsRemovesOnlyOrphans() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      // A `planning` pin whose owner id matches a real instance row must survive the sweep --
      // only pins with no matching instance row are stale.
      try await harness.imageRows.pin(
        ownerType: .planning, ownerId: record.id.rawValue, digest: image.record.digest)
      let orphanId = InstanceID.generate()
      try await harness.imageRows.pin(
        ownerType: .planning, ownerId: orphanId.rawValue, digest: image.record.digest)

      let swept = try await harness.images.sweepStalePlanningPins(knownInstanceIDs: [record.id])

      #expect(swept == 1)
      let remainingPlanning = try await harness.imageRows.pins(ownerType: .planning)
      #expect(remainingPlanning.map(\.ownerId) == [record.id.rawValue])
    }
  }
}
