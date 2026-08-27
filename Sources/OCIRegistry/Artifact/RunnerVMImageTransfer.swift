import Foundation
import RunnerCore

/// Which producer's artifact schema a manifest speaks. RunnerVM only ever *publishes*
/// `runnervm`; `tart` is a read-only import path (spec §58).
public enum ImageArtifactFormat: String, Sendable, Codable, CaseIterable {
  case runnervm
  case tart
}

/// Why an image is being inspected. A pull into the local store is allowed to fetch anything
/// RunnerVM can read; a pull that exists to boot a VM (or to seed an image build) is not, because
/// an image with no guest agent could never take a job and refusing it early is the difference
/// between a fast error and a multi-gigabyte download followed by one.
public enum ImagePullPurpose: Sendable {
  case storage
  case instance
  case buildBase
}

/// A parsed remote artifact in whichever schema it turned out to be.
///
/// Everything below the transfer layer works off this rather than off a concrete artifact type, so
/// the reassembly path is shared byte for byte between the two formats.
public enum RemoteArtifact: Sendable, Equatable {
  case runnervm(RunnerVMArtifact)
  case tart(TartArtifact)

  public var format: ImageArtifactFormat {
    switch self {
    case .runnervm: .runnervm
    case .tart: .tart
    }
  }

  public var metadata: ImageMetadata {
    switch self {
    case let .runnervm(artifact): artifact.metadata
    case let .tart(artifact): artifact.metadata
    }
  }

  public var diskChunks: [PlacedChunk] {
    switch self {
    case let .runnervm(artifact): artifact.diskChunks
    case let .tart(artifact): artifact.diskChunks
    }
  }

  public var diskVirtualSize: UInt64 {
    switch self {
    case let .runnervm(artifact): artifact.diskVirtualSize
    case let .tart(artifact): artifact.diskVirtualSize
    }
  }

  /// sha256 of the whole reassembled disk. `nil` for tart: a flat tart manifest carries no
  /// whole-file digest, so per-chunk digests are the only end-to-end check available.
  public var diskContentDigest: String? {
    switch self {
    case let .runnervm(artifact): artifact.diskContentDigest
    case .tart: nil
    }
  }

  public var nvram: OCIDescriptor? {
    switch self {
    case let .runnervm(artifact): artifact.nvram
    case let .tart(artifact): artifact.nvram
    }
  }
}

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
    public let artifact: RemoteArtifact

    public var digest: ImageDigest {
      resolved.digest
    }

    public var format: ImageArtifactFormat {
      artifact.format
    }

    public var metadata: ImageMetadata {
      artifact.metadata
    }

    /// Compressed bytes a pull will move; use it to size progress and disk reservations. Checked
    /// arithmetic: chunk sizes come off a registry-supplied manifest.
    public var transferBytes: UInt64 {
      let chunkSizes = artifact.diskChunks.map { UInt64(clamping: $0.descriptor.size) }
      let nvramSize = UInt64(clamping: artifact.nvram?.size ?? 0)
      return checkedSum(chunkSizes + [nvramSize])
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
  ///
  /// - Parameter require: refuse anything that is not this format. Also steers index selection, so
  ///   a mirror that fronts both a RunnerVM and a tart manifest behind one tag can be asked for
  ///   either. `nil` auto-detects.
  /// - Parameter purpose: `.instance` / `.buildBase` additionally refuse an image with no guest
  ///   agent — after the config blobs, still before any disk chunk.
  public static func inspect(
    _ reference: OCIReference,
    registry: RegistryClient,
    require: ImageArtifactFormat? = nil,
    purpose: ImagePullPurpose = .storage,
    limits: ArtifactLimits = .default
  ) async throws -> RemoteImage {
    let resolved = try await registry.resolve(reference, preferring: require)
    let detected = try detectFormat(resolved.manifest)
    if let require, require != detected {
      throw RegistryError.unsupportedManifest(
        reason: "manifest is \(detected.rawValue), not \(require.rawValue)"
      )
    }
    let image = RemoteImage(
      resolved: resolved,
      artifact: try await parse(
        detected, resolved: resolved, reference: reference, registry: registry, limits: limits
      )
    )
    try requireRunnable(image, purpose: purpose)
    return image
  }

  /// Which schema a manifest speaks. RunnerVM's own `artifactType` is decisive; otherwise the only
  /// remaining candidate is tart's layer shape, and anything else is refused by name so the
  /// operator can see what the registry actually served.
  public static func detectFormat(_ manifest: OCIManifest) throws -> ImageArtifactFormat {
    if manifest.artifactType == RunnerVMMediaType.artifact { return .runnervm }
    if TartArtifact.looksLikeTart(manifest) { return .tart }
    throw RegistryError.unsupportedManifest(
      reason: "manifest is neither \(RunnerVMMediaType.artifact) nor \(TartMediaType.config)"
    )
  }

  public static func pull(
    _ reference: OCIReference, registry: RegistryClient, into staging: URL,
    require: ImageArtifactFormat? = nil, purpose: ImagePullPurpose = .storage,
    concurrency: Int = DiskLayerizer.defaultConcurrency, progress: TransferProgress? = nil
  ) async throws -> PulledImage {
    let remote = try await inspect(
      reference, registry: registry, require: require, purpose: purpose
    )
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
      placed: remote.artifact.diskChunks, to: diskURL, virtualSize: remote.artifact.diskVirtualSize,
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

  // MARK: - Helpers

  private static func parse(
    _ format: ImageArtifactFormat, resolved: ResolvedManifest, reference: OCIReference,
    registry: RegistryClient, limits: ArtifactLimits
  ) async throws -> RemoteArtifact {
    switch format {
    case .runnervm:
      let configBlob = try await registry.blob(
        resolved.manifest.config.digest, repository: reference.repositoryPath
      )
      return .runnervm(
        try RunnerVMArtifact.parse(
          manifest: resolved.manifest, configBlob: configBlob, limits: limits
        )
      )
    case .tart:
      return .tart(
        try await TartArtifact.fetch(
          resolved: resolved, reference: reference, registry: registry, limits: limits
        )
      )
    }
  }

  /// Spec §58: an agentless image is importable but never bootable. Refusing here — with the
  /// config blobs read and not one disk chunk fetched — is what keeps a `vm create` against a
  /// tart image cheap.
  private static func requireRunnable(_ image: RemoteImage, purpose: ImagePullPurpose) throws {
    switch purpose {
    case .storage:
      return
    case .instance, .buildBase:
      guard !image.metadata.hasGuestAgent else { return }
      throw ImageError.noGuestAgent(
        digest: image.digest, reference: image.resolved.reference.description
      )
    }
  }
}
