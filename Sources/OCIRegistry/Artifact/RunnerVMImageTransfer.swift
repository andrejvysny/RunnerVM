import Foundation
import RunnerCore

/// Whole-image push and pull. This is the surface `ImageManager` calls; everything below it is
/// transport detail.
///
/// Pull writes `.partial` files into a caller-owned staging directory and stops there: verification
/// against the manifest happens here, atomic publication is `ImageStore`'s (spec §119, §120).
public enum RunnerVMImageTransfer {
  /// Stable names so an interrupted pull resumes into the same files.
  public static let diskFileName = "disk.img.partial"
  public static let nvramFileName = "nvram.bin.partial"

  public struct PushResult: Sendable, Equatable {
    /// `<registry>/<repository>@sha256:…` — the immutable form to record (spec §21).
    public let reference: OCIReference
    public let manifestDigest: ImageDigest
    public let manifest: OCIManifest
  }

  public struct RemoteImage: Sendable, Equatable {
    public let resolved: ResolvedManifest
    public let artifact: RunnerVMArtifact

    public var digest: ImageDigest {
      resolved.digest
    }

    public var metadata: ImageMetadata {
      artifact.metadata
    }

    /// Compressed bytes a pull will move; use it to size progress and disk reservations.
    public var transferBytes: UInt64 {
      UInt64(artifact.diskChunks.reduce(0) { $0 + $1.size } + (artifact.nvram?.size ?? 0))
    }
  }

  public struct PulledImage: Sendable, Equatable {
    public let reference: OCIReference
    public let manifestDigest: ImageDigest
    public let metadata: ImageMetadata
    public let diskURL: URL
    public let nvramURL: URL?
  }

  // MARK: - Push

  public static func push(
    diskURL: URL, nvramURL: URL?, metadata: ImageMetadata, to reference: OCIReference,
    registry: RegistryClient, staging: URL, chunkBytes: Int = DiskLayerizer.defaultChunkBytes,
    concurrency: Int = DiskLayerizer.defaultConcurrency, progress: TransferProgress? = nil
  ) async throws -> PushResult {
    let repository = reference.repositoryPath
    let disk = try await DiskLayerizer.push(
      diskURL: diskURL, repository: repository, registry: registry, staging: staging,
      chunkBytes: chunkBytes, concurrency: concurrency, progress: progress
    )
    guard disk.virtualSize == metadata.virtualDiskSizeBytes else {
      throw ImageError.metadataInvalid(
        reason: "metadata declares \(metadata.virtualDiskSizeBytes) bytes, disk is \(disk.virtualSize)"
      )
    }
    var nvram: OCIDescriptor?
    if let nvramURL {
      nvram = try await NVRAMLayer.push(
        fileURL: nvramURL, os: metadata.os, repository: repository, registry: registry
      )
    }
    let configBlob = try RunnerVMConfig(metadata: metadata).encoded()
    let configDigest = ContentDigest.hash(configBlob)
    if try await !registry.blobExists(configDigest, repository: repository) {
      _ = try await registry.pushBlob(configBlob, digest: configDigest, repository: repository)
    }
    let manifest = RunnerVMArtifact.makeManifest(
      config: OCIDescriptor(
        mediaType: RunnerVMMediaType.config, digest: configDigest, size: Int64(configBlob.count)
      ),
      diskChunks: disk.chunks, nvram: nvram, diskVirtualSize: disk.virtualSize,
      diskContentDigest: disk.contentDigest, createdAt: metadata.createdAt
    )
    let digest = try await registry.putManifest(
      manifest, repository: repository, reference: reference.manifestReference
    )
    return PushResult(
      reference: reference.canonical(withDigest: digest), manifestDigest: digest, manifest: manifest
    )
  }

  // MARK: - Pull

  /// Tag → digest plus the parsed artifact, without moving any disk bytes.
  ///
  /// Split out so the daemon can deduplicate concurrent pulls on the resolved digest before any
  /// download starts (spec §137).
  public static func inspect(
    _ reference: OCIReference,
    registry: RegistryClient
  ) async throws -> RemoteImage {
    let resolved = try await registry.resolve(reference)
    let configBlob = try await registry.blob(
      resolved.manifest.config.digest, repository: reference.repositoryPath
    )
    let artifact = try RunnerVMArtifact.parse(manifest: resolved.manifest, configBlob: configBlob)
    return RemoteImage(resolved: resolved, artifact: artifact)
  }

  public static func pull(
    _ reference: OCIReference, registry: RegistryClient, into staging: URL,
    concurrency: Int = DiskLayerizer.defaultConcurrency, progress: TransferProgress? = nil
  ) async throws -> PulledImage {
    let remote = try await inspect(reference, registry: registry)
    return try await pull(
      remote, registry: registry, into: staging, concurrency: concurrency, progress: progress
    )
  }

  /// Downloads an already-inspected image. Re-running this against the same staging directory
  /// resumes: verified chunks are skipped.
  public static func pull(
    _ remote: RemoteImage, registry: RegistryClient, into staging: URL,
    concurrency: Int = DiskLayerizer.defaultConcurrency, progress: TransferProgress? = nil
  ) async throws -> PulledImage {
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let repository = remote.resolved.reference.repositoryPath
    let diskURL = staging.appending(path: diskFileName)
    try await DiskLayerizer.pull(
      chunks: remote.artifact.diskChunks, to: diskURL, virtualSize: remote.artifact.diskVirtualSize,
      contentDigest: remote.artifact.diskContentDigest, repository: repository, registry: registry,
      concurrency: concurrency, progress: progress
    )
    var nvramURL: URL?
    if let nvram = remote.artifact.nvram {
      let url = staging.appending(path: nvramFileName)
      try await NVRAMLayer.pull(descriptor: nvram, to: url, repository: repository, registry: registry)
      let actual = try ContentDigest.hashFile(at: url)
      guard actual == nvram.digest else {
        throw RegistryError.digestMismatch(expected: nvram.digest, actual: actual)
      }
      nvramURL = url
      progress?.advance(by: UInt64(nvram.size))
    }
    return PulledImage(
      reference: remote.resolved.reference, manifestDigest: remote.digest,
      metadata: remote.artifact.metadata, diskURL: diskURL, nvramURL: nvramURL
    )
  }
}
