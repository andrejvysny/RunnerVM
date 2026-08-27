// Derived from openai/tart@16d186c Sources/tart/OCI/Manifest.swift:114-207 and
// Sources/tart/VMDirectory+OCI.swift:15-113 — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore

/// Media types tart publishes (spec §58). Verbatim from tart so a manifest is recognised by the
/// same strings tart itself writes; RunnerVM never *emits* any of these.
public enum TartMediaType {
  /// tart's manifests use the plain OCI image config as their `config` descriptor and carry no
  /// `artifactType` at all, which is what makes format detection a layer-shape question.
  public static let ociConfig = "application/vnd.oci.image.config.v1+json"

  public static let config = "application/vnd.cirruslabs.tart.config.v1"
  public static let diskV2 = "application/vnd.cirruslabs.tart.disk.v2"
  /// Refused: tart ≥2 no longer pulls these either.
  public static let legacyDiskV1 = "application/vnd.cirruslabs.tart.disk.v1"
  /// Refused: an Apple Sparse Image overlay is not a raw disk.
  public static let asifOverlay = "application/vnd.cirruslabs.tart.disk.asif.overlay.v1"
  public static let nvram = "application/vnd.cirruslabs.tart.nvram.v1"
}

/// Annotation keys tart writes, verbatim.
public enum TartAnnotation {
  // Manifest-level.
  public static let uncompressedDiskSize = "org.cirruslabs.tart.uncompressed-disk-size"
  public static let uploadTime = "org.cirruslabs.tart.upload-time"
  public static let diskBlockSize = "org.cirruslabs.tart.disk.block-size"
  /// Label on the OCI config blob, not an annotation.
  public static let diskFormatLabel = "org.cirruslabs.tart.disk.format"

  // Layer-level.
  public static let uncompressedSize = "org.cirruslabs.tart.uncompressed-size"
  public static let uncompressedContentDigest = "org.cirruslabs.tart.uncompressed-content-digest"
  /// Present only on stacked images, which RunnerVM refuses.
  public static let diskFileContentDigest = "org.cirruslabs.tart.disk-file-content-digest"
  public static let diskFileChunkCount = "org.cirruslabs.tart.disk-file-chunk-count"
}

extension ChunkAnnotationKeys {
  /// tart's chunk annotations, so `PlacedChunk.layout` can place a tart disk without forking.
  public static let tart = ChunkAnnotationKeys(
    uncompressedSize: TartAnnotation.uncompressedSize,
    uncompressedDigest: TartAnnotation.uncompressedContentDigest
  )
}

/// A validated tart manifest, converted to RunnerVM's own vocabulary.
///
/// Read-only by construction (spec §58): the disk is imported and re-sealed as a RunnerVM image,
/// and nothing here can be pushed back out in tart's format. The resulting `metadata` always
/// declares `guestAgent: false`, which is what stops such an image from ever running a job.
public struct TartArtifact: Sendable, Equatable {
  public let metadata: ImageMetadata
  public let vmConfig: TartVMConfig
  public let vmConfigLayer: OCIDescriptor
  /// In manifest order, which is disk order.
  public let diskChunks: [PlacedChunk]
  /// Always present: tart refuses to publish a VM without one.
  public let nvram: OCIDescriptor
  public let diskVirtualSize: UInt64
  public let createdAt: Date

  /// Deterministic stand-in when the manifest carries no `upload-time`. `ImageMetadata.createdAt`
  /// feeds the local content digest, so reading the wall clock here would make two imports of the
  /// same bytes produce two different images.
  static let unknownCreationDate = Date(timeIntervalSince1970: 0)

  /// Cheap shape test used only to pick a parser, never to accept one: a tart manifest has no
  /// `artifactType`, so the pair "OCI image config + tart config as the first layer" is the only
  /// signal available before any blob is fetched. Everything else is `layout`'s job.
  public static func looksLikeTart(_ manifest: OCIManifest) -> Bool {
    manifest.config.mediaType == TartMediaType.ociConfig
      && manifest.layers.first?.mediaType == TartMediaType.config
  }

  /// Structural validation with no blob fetched (rules S1–S9). `limits` runs first, so a manifest
  /// that lies about a size or a digest never reaches the shape checks.
  public static func layout(
    of manifest: OCIManifest, limits: ArtifactLimits = .default
  ) throws -> (vmConfig: OCIDescriptor, chunks: [OCIDescriptor], nvram: OCIDescriptor) {
    try limits.validate(manifest: manifest)
    try validateEnvelope(manifest)
    let configLayers = manifest.layers.filter { $0.mediaType == TartMediaType.config }
    guard configLayers.count == 1, manifest.layers.first?.mediaType == TartMediaType.config else {
      throw RegistryError.unsupportedManifest(
        reason: "expected exactly one \(TartMediaType.config) layer, first in the manifest"
      )
    }
    let nvramLayers = manifest.layers.filter { $0.mediaType == TartMediaType.nvram }
    guard nvramLayers.count == 1, manifest.layers.last?.mediaType == TartMediaType.nvram else {
      throw RegistryError.unsupportedManifest(
        reason: "expected exactly one \(TartMediaType.nvram) layer, last in the manifest"
      )
    }
    let chunks = Array(manifest.layers.dropFirst().dropLast())
    guard !chunks.isEmpty else {
      throw RegistryError.unsupportedManifest(reason: "manifest has no disk chunks")
    }
    try validateChunks(chunks)
    // A tart config layer is a few hundred bytes; anything config-sized is generous.
    guard configLayers[0].size <= limits.maxConfigBytes else {
      throw RegistryError.unsupportedManifest(
        reason: "tart config layer declares \(configLayers[0].size) bytes, over the "
          + "\(limits.maxConfigBytes)-byte limit"
      )
    }
    return (configLayers[0], chunks, nvramLayers[0])
  }

  /// Rules C1–C8 plus the size limits, once both small config blobs are in hand.
  public static func parse(
    manifest: OCIManifest, ociConfigBlob: Data, vmConfigBlob: Data, manifestDigest: String,
    limits: ArtifactLimits = .default
  ) throws -> TartArtifact {
    let (vmConfigLayer, chunkDescriptors, nvram) = try layout(of: manifest, limits: limits)
    let vmConfig = try TartVMConfig.decode(vmConfigBlob)
    let ociConfig = try TartOCIConfig.decode(ociConfigBlob)
    // C1: the chunks are the only authority on the disk's length; C2 makes the manifest's own
    // claim agree with them rather than the other way round.
    let placed = try PlacedChunk.layout(of: chunkDescriptors, virtualSize: nil, keys: .tart)
    let virtualSize = PlacedChunk.totalBytes(placed)
    try validateDeclaredDiskSize(manifest, virtualSize: virtualSize)
    try limits.validate(virtualDiskBytes: virtualSize)
    try limits.validate(nvram: nvram)
    let createdAt = manifest.annotation(TartAnnotation.uploadTime)
      .flatMap(parseTimestamp) ?? unknownCreationDate
    let metadata = try vmConfig.imageMetadata(
      ociConfig: ociConfig, virtualDiskSizeBytes: virtualSize, createdAt: createdAt,
      provenance: vmConfig.provenance(manifestDigest: manifestDigest)
    )
    return TartArtifact(
      metadata: metadata, vmConfig: vmConfig, vmConfigLayer: vmConfigLayer, diskChunks: placed,
      nvram: nvram, diskVirtualSize: virtualSize, createdAt: createdAt
    )
  }

  /// Fetches only the two small config blobs — the OCI stub and the tart config layer — so a
  /// refusal costs a few hundred bytes rather than gigabytes.
  public static func fetch(
    resolved: ResolvedManifest, reference: OCIReference, registry: RegistryClient,
    limits: ArtifactLimits = .default
  ) async throws -> TartArtifact {
    let repository = reference.repositoryPath
    let (vmConfigLayer, _, _) = try layout(of: resolved.manifest, limits: limits)
    let ociConfigBlob = try await registry.blob(
      resolved.manifest.config.digest, repository: repository
    )
    let vmConfigBlob = try await registry.blob(vmConfigLayer.digest, repository: repository)
    return try parse(
      manifest: resolved.manifest, ociConfigBlob: ociConfigBlob, vmConfigBlob: vmConfigBlob,
      manifestDigest: resolved.digest.rawValue, limits: limits
    )
  }

  // MARK: - Structural rules

  /// S1 and S2: it has to be an OCI image manifest whose config descriptor is an OCI image config.
  private static func validateEnvelope(_ manifest: OCIManifest) throws {
    guard manifest.schemaVersion == 2, manifest.mediaType == RunnerVMMediaType.ociManifest else {
      throw RegistryError.unsupportedManifest(
        reason: "expected an OCI image manifest, got \(manifest.mediaType) v\(manifest.schemaVersion)"
      )
    }
    guard manifest.config.mediaType == TartMediaType.ociConfig else {
      throw RegistryError.unsupportedManifest(
        reason: "config media type \(manifest.config.mediaType), expected \(TartMediaType.ociConfig)"
      )
    }
    guard !manifest.layers.contains(where: { $0.mediaType == TartMediaType.legacyDiskV1 }) else {
      throw RegistryError.unsupportedManifest(
        reason: "manifest uses the legacy \(TartMediaType.legacyDiskV1) disk layer; "
          + "re-push the image with tart ≥2"
      )
    }
  }

  /// S7–S9: every middle layer must be a flat `disk.v2` chunk carrying both size and digest.
  private static func validateChunks(_ chunks: [OCIDescriptor]) throws {
    for chunk in chunks {
      guard chunk.mediaType == TartMediaType.diskV2 else {
        let detail = chunk.mediaType == TartMediaType.asifOverlay
          ? "ASIF overlay layers are not supported; only a flat raw tart disk can be imported"
          : "unsupported disk chunk media type \(chunk.mediaType)"
        throw RegistryError.unsupportedManifest(reason: detail)
      }
      guard chunk.annotation(TartAnnotation.diskFileChunkCount) == nil else {
        throw RegistryError.unsupportedManifest(
          reason: "stacked tart images are not supported; pull a flat image instead"
        )
      }
      _ = try chunk.requiredUInt64Annotation(TartAnnotation.uncompressedSize)
      _ = try chunk.requiredAnnotation(TartAnnotation.uncompressedContentDigest)
    }
  }

  /// C2. The annotation is optional in tart's own writer, so its absence is not an error — but a
  /// value that disagrees with the chunks is, because one of the two is then lying about how much
  /// disk this host is about to allocate.
  private static func validateDeclaredDiskSize(
    _ manifest: OCIManifest, virtualSize: UInt64
  ) throws {
    guard let declared = manifest.annotation(TartAnnotation.uncompressedDiskSize) else { return }
    guard let value = UInt64(declared) else {
      throw RegistryError.unsupportedManifest(
        reason: "annotation \(TartAnnotation.uncompressedDiskSize) is not a number"
      )
    }
    guard value == virtualSize else {
      throw RegistryError.unsupportedManifest(
        reason: "manifest declares \(value) disk bytes but the chunks describe \(virtualSize)"
      )
    }
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
  }
}
