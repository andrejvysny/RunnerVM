import Darwin
import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Per-instance directories under `instances/` (spec §22).
///
/// An instance is an APFS clone of an immutable image blob plus its own mutable state. Everything is
/// built under `instances/.tmp/<uuid>` and promoted with a single `rename(2)`, so a crash leaves
/// either a complete instance or a clearly temporary directory — never a half-valid one (spec §120).
public actor InstanceStore {
  private let paths: RunnerPaths
  private let images: ImageStore
  private let allowFullCopy: Bool
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    paths: RunnerPaths, images: ImageStore, allowFullCopy: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() }, logger: Logger = Logger(component: .image)
  ) {
    self.paths = paths
    self.images = images
    self.allowFullCopy = allowFullCopy
    self.now = now
    self.logger = logger
  }

  // MARK: - Layout

  private var stagingRoot: URL { paths.instancesDir.appending(path: ".tmp", directoryHint: .isDirectory) }

  private func stagingDirectory(_ id: InstanceID) -> URL {
    stagingRoot.appending(path: id.rawValue, directoryHint: .isDirectory)
  }

  /// Reflects what is on disk today: `nvram` is present only when the instance actually has one.
  public func layout(for id: InstanceID) -> VMInstanceLayout {
    let directory = paths.instanceDir(id)
    return VMInstanceLayout(
      instanceId: id, directory: directory,
      hasNVRAM: FileSystem.exists(VMInstanceLayout.nvramPath(in: directory))
    )
  }

  // MARK: - Materialize

  /// Clones an image into a new instance directory and publishes it atomically.
  ///
  /// `diskBytes` may exceed the image's virtual size; the clone is simply truncated up, which is free
  /// on a sparse raw disk, and the guest agent grows the partition at boot. Shrinking is impossible.
  public func materialize(
    instanceId: InstanceID, image: ImageDigest, diskBytes: UInt64, spec: some Encodable & Sendable
  ) async throws -> MaterializedInstance {
    let info = try await images.inspect(digest: image)
    guard let diskLayer = info.manifest.layer(.disk) else {
      throw ImageError.manifestUnsupported(reason: "image \(image) has no disk layer")
    }
    guard diskBytes >= diskLayer.sizeBytes else {
      throw ImageError.diskSmallerThanImage(requestedBytes: diskBytes, imageBytes: diskLayer.sizeBytes)
    }
    let published = paths.instanceDir(instanceId)
    guard !FileSystem.exists(published) else {
      throw ImageError.cloneFailed(reason: "instance directory already exists: \(instanceId)")
    }

    try FileSystem.ensureDirectory(stagingRoot, permissions: 0o700)
    let staging = stagingDirectory(instanceId)
    // A leftover from an earlier failed attempt for this exact id is dead by definition.
    try FileSystem.removeIfPresent(staging)
    try FileSystem.ensureDirectory(staging, permissions: 0o700)

    let method = try await build(in: staging, instanceId: instanceId, image: image, info: info,
                                 diskBytes: diskBytes, spec: spec)
    FileSystem.fsyncDirectory(staging)
    try FileSystem.atomicRename(from: staging, to: published)
    FileSystem.fsyncDirectory(paths.instancesDir)
    logger.info(
      "instance materialized",
      metadata: .context(instance: instanceId, imageDigest: image)
        .merging(["clone_method": .string(method.rawValue)]) { $1 }
    )
    return MaterializedInstance(layout: layout(for: instanceId), cloneMethod: method)
  }

  private func build(
    in staging: URL, instanceId: InstanceID, image: ImageDigest, info: ImageInfo,
    diskBytes: UInt64, spec: some Encodable & Sendable
  ) async throws -> CloneMethod {
    let diskBlob = try await images.blobURL(role: .disk, digest: image)
    var nvramSource: VMDirectoryStaging.DiskSource?
    if info.manifest.layer(.nvram) != nil {
      nvramSource = .blob(try await images.blobURL(role: .nvram, digest: image))
    }
    return try VMDirectoryStaging.stage(
      into: staging, disk: .blob(diskBlob), nvram: nvramSource, diskBytes: diskBytes,
      imageBytes: info.manifest.layer(.disk)?.sizeBytes ?? 0, spec: spec, allowFullCopy: allowFullCopy
    )
  }

  // MARK: - Inventory

  /// Idempotent: deleting an instance that is already gone is success (spec §119 resumability).
  public func delete(instanceId: InstanceID) throws {
    try FileSystem.removeIfPresent(paths.instanceDir(instanceId))
    try FileSystem.removeIfPresent(stagingDirectory(instanceId))
  }

  public func listDirectories() throws -> [InstanceID] {
    guard FileSystem.exists(paths.instancesDir) else { return [] }
    let children = try FileManager.default.contentsOfDirectory(
      at: paths.instancesDir, includingPropertiesForKeys: nil
    )
    return children
      .filter { !$0.lastPathComponent.hasPrefix(".") && FileSystem.isDirectory($0) }
      .map { InstanceID(rawValue: $0.lastPathComponent) }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// Directories with no matching database row. They are *candidates*, not garbage: the reconciler
  /// marks an orphan and applies a grace period before deleting anything (spec §111).
  public func orphanCandidates(known: Set<InstanceID>) throws -> [InstanceID] {
    let orphans = try listDirectories().filter { !known.contains($0) }
    for orphan in orphans {
      logger.warning("orphan detected", metadata: .context(instance: orphan))
    }
    return orphans
  }

  public func allocatedBytes(instanceId: InstanceID) -> UInt64 {
    FileSystem.allocatedBytes(at: paths.instanceDir(instanceId))
  }

  // MARK: - Diagnostics (spec §74)

  /// Writes `failure.json`. The directory is created when missing so a failure during materialization
  /// still leaves evidence rather than being lost because publication never happened.
  public func recordFailure(instanceId: InstanceID, _ record: FailureRecord) throws {
    let directory = paths.instanceDir(instanceId)
    try FileSystem.ensureDirectory(directory, permissions: 0o700)
    try FileSystem.write(
      try CanonicalJSON.encode(record),
      to: directory.appending(path: VMInstanceLayout.failureName), mode: 0o600
    )
  }

  public func failureRecord(instanceId: InstanceID) throws -> FailureRecord? {
    let url = paths.instanceDir(instanceId).appending(path: VMInstanceLayout.failureName)
    guard FileSystem.exists(url) else { return nil }
    return try CanonicalJSON.decode(FailureRecord.self, from: try FileSystem.read(url))
  }

  /// Deletes failed instance directories whose evidence has outlived `diagnostics.failedInstanceRetention`.
  /// Instances without a `failure.json` are never touched here: they belong to the reconciler.
  @discardableResult
  public func retentionSweep(olderThan retention: Duration) throws -> [InstanceID] {
    let cutoff = now().addingTimeInterval(-FileSystem.seconds(retention))
    var swept: [InstanceID] = []
    for id in try listDirectories() {
      guard let recorded = try failureTimestamp(instanceId: id), recorded < cutoff else { continue }
      try delete(instanceId: id)
      swept.append(id)
      logger.info("failed instance swept", metadata: .context(instance: id))
    }
    return swept
  }

  /// Prefers the recorded time over the file's mtime, so a touched file cannot extend retention.
  private func failureTimestamp(instanceId: InstanceID) throws -> Date? {
    let url = paths.instanceDir(instanceId).appending(path: VMInstanceLayout.failureName)
    guard FileSystem.exists(url) else { return nil }
    if let record = try? failureRecord(instanceId: instanceId) { return record.occurredAt }
    return try FileSystem.modificationDate(at: url)
  }

  /// Drops `instances/.tmp` directories left by a crashed or failed materialization.
  @discardableResult
  public func sweepStaging(olderThan retention: Duration) throws -> [URL] {
    try FileSystem.sweepStaleDirectories(in: stagingRoot, olderThan: retention, now: now())
  }

  /// True while a vmworker holds the `fcntl` write lock on `worker.lock` (spec plan C1 fencing).
  public func workerLockHolder(instanceId: InstanceID) throws -> pid_t? {
    try WorkerLock.holderPID(at: layout(for: instanceId).workerLock)
  }
}
