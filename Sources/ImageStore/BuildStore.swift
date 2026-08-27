import Darwin
import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Per-build directories under `builds/` (Phase 4/5 image builder). Same discipline as
/// `InstanceStore`: everything is built under `builds/.tmp/<uuid>` and promoted into
/// `builds/<id>/vm` with a single `rename(2)`, so a crash leaves either a complete build directory
/// or a clearly temporary one, never a half-valid one.
public actor BuildStore {
  private let paths: RunnerPaths
  private let images: ImageStore
  private let allowFullCopy: Bool
  private let logger: Logger

  public init(
    paths: RunnerPaths, images: ImageStore, allowFullCopy: Bool = false,
    logger: Logger = Logger(component: .image)
  ) {
    self.paths = paths
    self.images = images
    self.allowFullCopy = allowFullCopy
    self.logger = logger
  }

  // MARK: - Layout

  private var stagingRoot: URL { paths.buildsDir.appending(path: ".tmp", directoryHint: .isDirectory) }

  private func stagingDirectory(_ id: ImageBuildID) -> URL {
    stagingRoot.appending(path: id.rawValue, directoryHint: .isDirectory)
  }

  /// Reflects what is on disk today: `nvram` is present only when the build actually has one.
  public func layout(for id: ImageBuildID) -> VMBuildLayout {
    let directory = paths.buildVMDir(id)
    return VMBuildLayout(
      buildId: id, directory: directory,
      hasNVRAM: FileSystem.exists(VMInstanceLayout.nvramPath(in: directory))
    )
  }

  // MARK: - Materialize

  /// Clones an existing local image's disk (and nvram, if it has one) into a fresh build directory.
  @discardableResult
  public func materialize(
    buildId: ImageBuildID, from image: ImageDigest, diskBytes: UInt64, spec: some Encodable & Sendable
  ) async throws -> VMBuildLayout {
    let info = try await images.inspect(digest: image)
    guard let diskLayer = info.manifest.layer(.disk) else {
      throw ImageError.manifestUnsupported(reason: "image \(image) has no disk layer")
    }
    guard diskBytes >= diskLayer.sizeBytes else {
      throw ImageError.diskSmallerThanImage(requestedBytes: diskBytes, imageBytes: diskLayer.sizeBytes)
    }
    let diskBlob = try await images.blobURL(role: .disk, digest: image)
    var nvramSource: VMDirectoryStaging.DiskSource?
    if info.manifest.layer(.nvram) != nil {
      nvramSource = .blob(try await images.blobURL(role: .nvram, digest: image))
    }
    return try publish(
      buildId: buildId, disk: .blob(diskBlob), nvram: nvramSource, diskBytes: diskBytes,
      imageBytes: diskLayer.sizeBytes, spec: spec
    )
  }

  /// Clones an arbitrary raw disk already on this host -- a `FROM cloudImage:`/`FROM registry:`
  /// base staged outside the local image store. No nvram: vmworker creates a fresh EFI variable
  /// store for a Linux base the same way it does for an instance whose image ships without one.
  @discardableResult
  public func materialize(
    buildId: ImageBuildID, fromRawDisk disk: URL, diskBytes: UInt64, spec: some Encodable & Sendable
  ) throws -> VMBuildLayout {
    try publish(
      buildId: buildId, disk: .file(disk), nvram: nil, diskBytes: diskBytes, imageBytes: 0, spec: spec
    )
  }

  private func publish(
    buildId: ImageBuildID, disk: VMDirectoryStaging.DiskSource, nvram: VMDirectoryStaging.DiskSource?,
    diskBytes: UInt64, imageBytes: UInt64, spec: some Encodable & Sendable
  ) throws -> VMBuildLayout {
    let published = paths.buildVMDir(buildId)
    guard !FileSystem.exists(published) else {
      throw ImageError.cloneFailed(reason: "build directory already exists: \(buildId)")
    }

    try FileSystem.ensureDirectory(stagingRoot, permissions: 0o700)
    let staging = stagingDirectory(buildId)
    // A leftover from an earlier failed attempt for this exact id is dead by definition.
    try FileSystem.removeIfPresent(staging)
    try FileSystem.ensureDirectory(staging, permissions: 0o700)

    let method = try VMDirectoryStaging.stage(
      into: staging, disk: disk, nvram: nvram, diskBytes: diskBytes, imageBytes: imageBytes,
      spec: spec, allowFullCopy: allowFullCopy
    )
    FileSystem.fsyncDirectory(staging)
    try FileSystem.ensureDirectory(paths.buildDir(buildId), permissions: 0o700)
    try FileSystem.atomicRename(from: staging, to: published)
    FileSystem.fsyncDirectory(paths.buildDir(buildId))
    logger.info(
      "build materialized",
      metadata: ["build_id": .string(buildId.rawValue), "clone_method": .string(method.rawValue)]
    )
    return layout(for: buildId)
  }

  // MARK: - Inventory

  /// Idempotent: deleting a build that is already gone is success.
  public func delete(buildId: ImageBuildID) throws {
    try FileSystem.removeIfPresent(paths.buildDir(buildId))
    try FileSystem.removeIfPresent(stagingDirectory(buildId))
  }

  public func listDirectories() throws -> [ImageBuildID] {
    guard FileSystem.exists(paths.buildsDir) else { return [] }
    let children = try FileManager.default.contentsOfDirectory(
      at: paths.buildsDir, includingPropertiesForKeys: nil
    )
    return children
      .filter { !$0.lastPathComponent.hasPrefix(".") && FileSystem.isDirectory($0) }
      .map { ImageBuildID(rawValue: $0.lastPathComponent) }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// True while a vmworker holds the `fcntl` write lock on this build's `worker.lock`.
  public func workerLockHolder(buildId: ImageBuildID) throws -> pid_t? {
    try WorkerLock.holderPID(at: layout(for: buildId).workerLock)
  }

  public func allocatedBytes(buildId: ImageBuildID) -> UInt64 {
    FileSystem.allocatedBytes(at: paths.buildDir(buildId))
  }
}
