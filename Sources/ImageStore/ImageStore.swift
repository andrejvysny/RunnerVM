import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Result of a local import. `created == false` means identical content was already stored, so the
/// existing manifest was returned untouched.
public struct ImportedImage: Sendable, Equatable {
  public let digest: ImageDigest
  public let manifest: LocalImageManifest
  public let manifestDirectory: URL
  public let created: Bool
}

/// A stored image plus its measured footprint.
public struct ImageInfo: Sendable, Equatable {
  public let manifest: LocalImageManifest
  public let metadata: ImageMetadata
  /// Blocks actually committed on disk (`st_blocks * 512`), which for a sparse image is far below
  /// `virtualBytes`.
  public let allocatedBytes: UInt64
  /// Logical size of all layers.
  public let virtualBytes: UInt64

  public var digest: ImageDigest { manifest.digest }
}

/// The immutable local image store (spec §20–§24).
///
/// Content-addressed blobs plus per-image manifests. Nothing published here is ever modified: every
/// write lands in `images/.tmp/<uuid>` and is promoted with `rename(2)` (spec §120). The actor is the
/// single writer, which is what makes "publish blobs, then the manifest that references them" and
/// "delete a manifest, then its now-unreferenced blobs" safe without a lock file.
public actor ImageStore {
  private let paths: RunnerPaths
  private let logger: Logger

  public init(paths: RunnerPaths, logger: Logger = Logger(component: .image)) {
    self.paths = paths
    self.logger = logger
  }

  // MARK: - Layout

  public nonisolated func manifestDirectory(for digest: ImageDigest) -> URL? {
    digest.manifestDirectoryName.map {
      paths.imageManifestsDir.appending(path: $0, directoryHint: .isDirectory)
    }
  }

  private func requireManifestDirectory(_ digest: ImageDigest) throws -> URL {
    guard let directory = manifestDirectory(for: digest) else {
      throw ImageError.referenceInvalid(reference: digest.rawValue)
    }
    return directory
  }

  private var stagingRoot: URL { paths.imagesDir.appending(path: ".tmp", directoryHint: .isDirectory) }
  private var blobRoot: URL { paths.imageBlobsDir.appending(path: "sha256", directoryHint: .isDirectory) }

  private func blobPath(forContent digest: String) throws -> URL {
    guard let hex = ImageDigest(rawValue: digest).sha256Hex else {
      throw ImageError.digestMismatch(expected: "sha256:<64 hex>", actual: digest)
    }
    return blobRoot.appending(path: hex.prefix(2), directoryHint: .isDirectory).appending(path: hex)
  }

  private func prepareLayout() throws {
    try FileSystem.ensureDirectory(paths.imageManifestsDir)
    try FileSystem.ensureDirectory(blobRoot)
    try FileSystem.ensureDirectory(stagingRoot, permissions: 0o700)
  }

  // MARK: - Import

  /// Imports a raw disk (plus optional EFI store / macOS auxiliary storage) already on this host.
  ///
  /// Idempotent by content: re-importing identical bytes returns the existing digest and stores no
  /// second copy of any blob.
  public func importLocal(
    disk: URL, nvram: URL?, metadata: ImageMetadata, name: String? = nil
  ) async throws -> ImportedImage {
    try prepareLayout()
    let staging = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    // Local import has nothing resumable to offer (unlike a registry pull, spec §119), so a failed
    // attempt leaves nothing behind.
    defer { try? FileSystem.removeIfPresent(staging) }
    try FileSystem.ensureDirectory(staging, permissions: 0o700)

    try validate(metadata: metadata, disk: disk, nvram: nvram)
    let layers = try stageLayers(disk: disk, nvram: nvram, in: staging)
    let metadataBytes = try CanonicalJSON.encode(metadata)
    let metadataDigest = SHA256Hasher.hash(metadataBytes)
    let digest = try LocalImageManifest.computeDigest(
      os: metadata.os, layers: layers, metadataDigest: metadataDigest
    )

    if let existing = try storedImage(digest: digest) {
      logger.debug("image already present", metadata: .context(imageDigest: digest))
      return ImportedImage(
        digest: digest, manifest: existing.manifest,
        manifestDirectory: try requireManifestDirectory(digest), created: false
      )
    }
    let manifest = LocalImageManifest(
      digest: digest, os: metadata.os, layers: layers, metadataDigest: metadataDigest, name: name
    )
    try publishBlobs(layers, from: staging)
    let published = try publishManifest(manifest, metadataBytes: metadataBytes, from: staging)
    logger.info(
      "image imported",
      metadata: .context(imageDigest: digest).merging(["name": .string(name ?? "-")]) { $1 }
    )
    return published
  }

  private func validate(metadata: ImageMetadata, disk: URL, nvram: URL?) throws {
    guard metadata.schemaVersion == ImageMetadata.currentSchemaVersion else {
      throw ImageError.manifestUnsupported(reason: "metadata schemaVersion \(metadata.schemaVersion)")
    }
    guard metadata.diskFormat == .raw else {
      throw ImageError.manifestUnsupported(
        reason: "disk format \(metadata.diskFormat.rawValue) is not supported in v1"
      )
    }
    guard FileSystem.exists(disk) else {
      throw ImageError.notFound(reference: disk.path(percentEncoded: false))
    }
    let size = try FileSystem.fileSize(at: disk)
    guard size == metadata.virtualDiskSizeBytes else {
      throw ImageError.metadataInvalid(
        reason: "virtualDiskSizeBytes \(metadata.virtualDiskSizeBytes) != disk size \(size)"
      )
    }
    try validatePlatform(metadata: metadata, nvram: nvram)
  }

  /// A macOS image cannot boot without the hardware model and the auxiliary storage it was sealed
  /// with; instance identity (machine id, MAC) is generated per instance instead (spec §25).
  private func validatePlatform(metadata: ImageMetadata, nvram: URL?) throws {
    switch metadata.os {
    case .macos:
      guard let model = metadata.macos?.hardwareModel, !model.isEmpty else {
        throw ImageError.metadataInvalid(reason: "macOS image is missing macos.hardwareModel")
      }
      guard metadata.boot.type == .macos else {
        throw ImageError.metadataInvalid(reason: "macOS image must declare boot.type = macos")
      }
      guard nvram != nil else {
        throw ImageError.metadataInvalid(reason: "macOS image is missing auxiliary storage")
      }
    case .linux:
      guard metadata.boot.type == .efi else {
        throw ImageError.metadataInvalid(reason: "linux image must declare boot.type = efi")
      }
      guard metadata.macos == nil else {
        throw ImageError.metadataInvalid(reason: "linux image must not carry macos platform data")
      }
    }
  }

  private func stageLayers(disk: URL, nvram: URL?, in staging: URL) throws -> [LocalImageManifest.Layer] {
    var layers: [LocalImageManifest.Layer] = []
    for (role, source) in [(LocalImageManifest.LayerRole.disk, disk), (.nvram, nvram)] {
      guard let source else { continue }
      guard FileSystem.exists(source) else {
        throw ImageError.notFound(reference: source.path(percentEncoded: false))
      }
      let staged = staging.appending(path: role.rawValue)
      // A full copy is always acceptable here: the import source is an arbitrary host path that may
      // live on another volume. The CoW guarantee that matters is instance clone (§23).
      _ = try APFSClone.cloneOrCopy(from: source, to: staged, allowFullCopy: true)
      layers.append(LocalImageManifest.Layer(
        role: role, digest: try SHA256Hasher.hashFile(at: staged),
        sizeBytes: try FileSystem.fileSize(at: staged)
      ))
    }
    return layers.sorted { $0.role < $1.role }
  }

  /// Blobs land before the manifest that names them, so a manifest never points at missing content.
  /// A crash in between leaves blobs that `unreferencedBlobs()` reclaims.
  private func publishBlobs(_ layers: [LocalImageManifest.Layer], from staging: URL) throws {
    for layer in layers {
      let staged = staging.appending(path: layer.role.rawValue)
      let target = try blobPath(forContent: layer.digest)
      guard !FileSystem.exists(target) else {
        try FileSystem.removeIfPresent(staged)
        continue
      }
      try FileSystem.ensureDirectory(target.deletingLastPathComponent())
      try FileSystem.setMode(0o444, at: staged)
      try FileSystem.atomicRename(from: staged, to: target)
    }
    FileSystem.fsyncDirectory(blobRoot)
  }

  private func publishManifest(
    _ manifest: LocalImageManifest, metadataBytes: Data, from staging: URL
  ) throws -> ImportedImage {
    let target = try requireManifestDirectory(manifest.digest)
    let stagedDir = staging.appending(path: "manifest", directoryHint: .isDirectory)
    try FileSystem.ensureDirectory(stagedDir, permissions: 0o755)
    try FileSystem.write(metadataBytes, to: stagedDir.appending(path: Self.metadataFile), mode: 0o444)
    try FileSystem.write(
      try CanonicalJSON.encode(manifest), to: stagedDir.appending(path: Self.manifestFile), mode: 0o444
    )
    FileSystem.fsyncDirectory(stagedDir)
    do {
      try FileSystem.atomicRename(from: stagedDir, to: target)
    } catch let error as NSError where error.code == Int(EEXIST) || error.code == Int(ENOTEMPTY) {
      // Lost a publication race for identical content: the winner's manifest is equivalent.
      guard let existing = try storedImage(digest: manifest.digest) else { throw error }
      return ImportedImage(
        digest: manifest.digest, manifest: existing.manifest, manifestDirectory: target, created: false
      )
    }
    // Read-only only after the rename: an unwritable staging directory could not be cleaned up.
    try? FileSystem.setMode(0o555, at: target)
    FileSystem.fsyncDirectory(paths.imageManifestsDir)
    return ImportedImage(
      digest: manifest.digest, manifest: manifest, manifestDirectory: target, created: true
    )
  }

  // MARK: - Read

  public func exists(_ digest: ImageDigest) -> Bool {
    guard let dir = manifestDirectory(for: digest) else { return false }
    return FileSystem.exists(dir.appending(path: Self.manifestFile))
  }

  public func inspect(digest: ImageDigest) throws -> ImageInfo {
    guard let info = try storedImage(digest: digest) else {
      throw ImageError.notFound(reference: digest.rawValue)
    }
    return info
  }

  public func list() throws -> [ImageInfo] {
    try manifestDirectories().compactMap { directory in
      guard let digest = ImageDigest.fromManifestDirectoryName(directory.lastPathComponent)
      else { return nil }
      return try storedImage(digest: digest)
    }
  }

  /// Absolute path of one layer's blob. vmworker and `InstanceStore` clone from here; the file is
  /// mode `0444` and must never be opened for writing.
  public func blobURL(
    role: LocalImageManifest.LayerRole, digest: ImageDigest
  ) throws -> URL {
    let info = try inspect(digest: digest)
    guard let layer = info.manifest.layer(role) else {
      throw ImageError.manifestUnsupported(reason: "image \(digest) has no \(role.rawValue) layer")
    }
    return try blobPath(forContent: layer.digest)
  }

  /// Re-hashes every blob against the manifest. Used by `runnerctl doctor` and before sealing.
  public func verify(digest: ImageDigest) throws {
    let info = try inspect(digest: digest)
    let metadataBytes = try FileSystem.read(metadataURL(for: digest))
    let actualMetadata = SHA256Hasher.hash(metadataBytes)
    guard actualMetadata == info.manifest.metadataDigest else {
      throw ImageError.digestMismatch(expected: info.manifest.metadataDigest, actual: actualMetadata)
    }
    for layer in info.manifest.layers {
      let blob = try blobPath(forContent: layer.digest)
      guard FileSystem.exists(blob) else { throw ImageError.notFound(reference: layer.digest) }
      let actual = try SHA256Hasher.hashFile(at: blob)
      guard actual == layer.digest else {
        throw ImageError.digestMismatch(expected: layer.digest, actual: actual)
      }
    }
  }

  // MARK: - Delete / GC

  /// Removes the manifest and any blob no other manifest references. The caller guarantees the image
  /// carries no `image_pins` rows (spec §110) — this module owns files, not reference accounting.
  public func delete(digest: ImageDigest) throws {
    guard let dir = manifestDirectory(for: digest), FileSystem.exists(dir) else { return }
    try FileSystem.removeIfPresent(dir)
    for blob in try unreferencedBlobs() {
      try FileSystem.removeIfPresent(blob)
    }
    logger.info("image deleted", metadata: .context(imageDigest: digest))
  }

  /// Blobs no manifest references: either freed by `delete`, or orphaned by a crash between
  /// `publishBlobs` and `publishManifest`.
  public func unreferencedBlobs() throws -> [URL] {
    var referenced: Set<String> = []
    for directory in try manifestDirectories() {
      guard let manifest = try? readManifest(in: directory) else { continue }
      for layer in manifest.layers { referenced.insert(layer.digest) }
    }
    guard FileSystem.exists(blobRoot),
          let walker = FileManager.default.enumerator(at: blobRoot, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { entry in
      guard let url = entry as? URL, !FileSystem.isDirectory(url) else { return nil }
      let digest = "sha256:" + url.lastPathComponent
      return referenced.contains(digest) ? nil : url
    }
  }

  /// Drops abandoned `images/.tmp` staging directories left by a crashed import.
  public func sweepStaging(olderThan retention: Duration, now: Date = Date()) throws -> Int {
    try FileSystem.sweepStaleDirectories(in: stagingRoot, olderThan: retention, now: now).count
  }

  // MARK: - Storage access

  static let manifestFile = "manifest.json"
  static let metadataFile = "metadata.json"

  private func metadataURL(for digest: ImageDigest) throws -> URL {
    try requireManifestDirectory(digest).appending(path: Self.metadataFile)
  }

  private func manifestDirectories() throws -> [URL] {
    guard FileSystem.exists(paths.imageManifestsDir) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: paths.imageManifestsDir, includingPropertiesForKeys: nil
    ).filter { FileSystem.isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func readManifest(in directory: URL) throws -> LocalImageManifest {
    try CanonicalJSON.decode(
      LocalImageManifest.self, from: try FileSystem.read(directory.appending(path: Self.manifestFile))
    )
  }

  private func storedImage(digest: ImageDigest) throws -> ImageInfo? {
    guard let directory = manifestDirectory(for: digest),
          FileSystem.exists(directory.appending(path: Self.manifestFile))
    else { return nil }
    let manifest = try readManifest(in: directory)
    let metadata = try CanonicalJSON.decode(
      ImageMetadata.self, from: try FileSystem.read(directory.appending(path: Self.metadataFile))
    )
    var allocated = FileSystem.allocatedBytes(at: directory)
    var virtual: UInt64 = 0
    for layer in manifest.layers {
      allocated += FileSystem.allocatedBytes(at: try blobPath(forContent: layer.digest))
      virtual += layer.sizeBytes
    }
    return ImageInfo(manifest: manifest, metadata: metadata, allocatedBytes: allocated, virtualBytes: virtual)
  }
}
