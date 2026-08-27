import Foundation
import RunnerCore

/// RunnerVM's own OCI artifact schema (spec §55, §56).
///
/// Tart's `application/vnd.cirruslabs.tart.*` types are deliberately not reused: an image published
/// by RunnerVM must not be mistaken for one a different tool can boot.
public enum RunnerVMMediaType {
  public static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
  public static let ociIndex = "application/vnd.oci.image.index.v1+json"

  /// `artifactType` on the manifest: what the whole thing is.
  public static let artifact = "application/vnd.runnervm.image.v1"
  /// Config blob: `ImageMetadata` plus `artifactSchemaVersion`.
  public static let config = "application/vnd.runnervm.config.v1+json"
  /// One ordered, independently decompressible slice of the raw disk (decision D7: LZ4, because
  /// Apple's `Compression` framework has no zstd).
  public static let diskChunk = "application/vnd.runnervm.disk.raw.v1+lz4"
  /// Linux EFI variable store, stored raw.
  public static let efi = "application/vnd.runnervm.efi.v1"
  /// macOS auxiliary storage, stored raw.
  public static let macOSAuxiliaryStorage = "application/vnd.runnervm.macos.auxiliary-storage.v1"

  public static func nvram(for os: GuestOS) -> String {
    switch os {
    case .linux: efi
    case .macos: macOSAuxiliaryStorage
    }
  }

  static let nvramTypes: Set<String> = [efi, macOSAuxiliaryStorage]
}

public enum RunnerVMAnnotation {
  /// Decimal position of a disk chunk. Redundant with layer order, and checked against it.
  public static let chunkIndex = "dev.runnervm.chunk.index"
  public static let chunkUncompressedSize = "dev.runnervm.chunk.uncompressed-size"
  /// Lets a resumed pull verify an already-written region without re-downloading it.
  public static let chunkUncompressedDigest = "dev.runnervm.chunk.uncompressed-digest"
  public static let diskVirtualSize = "dev.runnervm.disk.virtual-size"
  /// sha256 of the entire reassembled raw disk, so a pull is verified end to end.
  public static let diskContentDigest = "dev.runnervm.disk.content-digest"
  public static let created = "org.opencontainers.image.created"
}

/// The config blob. Encoded flat: `ImageMetadata`'s keys plus `artifactSchemaVersion`, so a reader
/// that only knows `ImageMetadata` can still parse it.
public struct RunnerVMConfig: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var artifactSchemaVersion: Int
  public var metadata: ImageMetadata

  public init(metadata: ImageMetadata, artifactSchemaVersion: Int = RunnerVMConfig.currentSchemaVersion) {
    self.artifactSchemaVersion = artifactSchemaVersion
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey { case artifactSchemaVersion }

  public init(from decoder: any Decoder) throws {
    metadata = try ImageMetadata(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artifactSchemaVersion = try container.decode(Int.self, forKey: .artifactSchemaVersion)
  }

  public func encode(to encoder: any Encoder) throws {
    try metadata.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(artifactSchemaVersion, forKey: .artifactSchemaVersion)
  }

  public func encoded() throws -> Data {
    try OCIJSON.encode(self)
  }

  public static func decode(_ data: Data) throws -> RunnerVMConfig {
    do {
      return try OCIJSON.decode(RunnerVMConfig.self, from: data)
    } catch {
      throw RegistryError.unsupportedManifest(reason: "config blob is not a RunnerVM config: \(error)")
    }
  }
}

/// A validated RunnerVM manifest: ordered disk chunks, optional NVRAM, and the sizes/digests needed
/// to reassemble and verify the disk.
public struct RunnerVMArtifact: Sendable, Equatable {
  public let metadata: ImageMetadata
  public let configDescriptor: OCIDescriptor
  /// In manifest order, which is disk order.
  public let diskChunks: [PlacedChunk]
  public let nvram: OCIDescriptor?
  public let diskVirtualSize: UInt64
  public let diskContentDigest: String
  public let createdAt: Date?

  /// Structural validation without fetching the config blob. `limits` runs first: a manifest that
  /// fails it is rejected before any of the checks below even look at it.
  public static func layout(
    of manifest: OCIManifest, limits: ArtifactLimits = .default
  ) throws -> (chunks: [OCIDescriptor], nvram: OCIDescriptor?) {
    try limits.validate(manifest: manifest)
    guard manifest.schemaVersion == 2, manifest.mediaType == RunnerVMMediaType.ociManifest else {
      throw RegistryError.unsupportedManifest(
        reason: "expected an OCI image manifest, got \(manifest.mediaType) v\(manifest.schemaVersion)"
      )
    }
    guard manifest.artifactType == RunnerVMMediaType.artifact else {
      throw RegistryError.unsupportedManifest(
        reason: "artifactType is \(manifest.artifactType ?? "absent"), expected \(RunnerVMMediaType.artifact)"
      )
    }
    guard manifest.config.mediaType == RunnerVMMediaType.config else {
      throw RegistryError.unsupportedManifest(reason: "config media type \(manifest.config.mediaType)")
    }
    let chunks = manifest.layers.filter { $0.mediaType == RunnerVMMediaType.diskChunk }
    let nvramLayers = manifest.layers.filter { RunnerVMMediaType.nvramTypes.contains($0.mediaType) }
    guard chunks.count + nvramLayers.count == manifest.layers.count else {
      let unknown = manifest.layers.map(\.mediaType)
        .filter { $0 != RunnerVMMediaType.diskChunk && !RunnerVMMediaType.nvramTypes.contains($0) }
      throw RegistryError.unsupportedManifest(reason: "unexpected layer media types \(Set(unknown))")
    }
    guard !chunks.isEmpty else {
      throw RegistryError.unsupportedManifest(reason: "manifest has no disk chunks")
    }
    guard nvramLayers.count <= 1, manifest.layers.prefix(chunks.count) == ArraySlice(chunks) else {
      throw RegistryError.unsupportedManifest(
        reason: "layers must be disk chunks in order, then at most one NVRAM layer"
      )
    }
    try validateChunkOrder(chunks)
    return (chunks, nvramLayers.first)
  }

  public static func parse(
    manifest: OCIManifest, configBlob: Data, limits: ArtifactLimits = .default
  ) throws -> RunnerVMArtifact {
    let (chunkDescriptors, nvram) = try layout(of: manifest, limits: limits)
    let config = try RunnerVMConfig.decode(configBlob)
    guard config.artifactSchemaVersion == RunnerVMConfig.currentSchemaVersion else {
      throw RegistryError.unsupportedManifest(
        reason: "artifactSchemaVersion \(config.artifactSchemaVersion) is not supported"
      )
    }
    guard let virtualSizeText = manifest.annotation(RunnerVMAnnotation.diskVirtualSize),
          let virtualSize = UInt64(virtualSizeText)
    else {
      throw RegistryError
        .unsupportedManifest(reason: "manifest is missing \(RunnerVMAnnotation.diskVirtualSize)")
    }
    guard let contentDigest = manifest.annotation(RunnerVMAnnotation.diskContentDigest) else {
      throw RegistryError
        .unsupportedManifest(reason: "manifest is missing \(RunnerVMAnnotation.diskContentDigest)")
    }
    try limits.validate(virtualDiskBytes: virtualSize)
    // Cross-checks the chunks' declared sizes against `virtualSize` with checked arithmetic; this
    // is also what used to be a plain, unchecked `reduce` here.
    let chunks = try PlacedChunk.layout(of: chunkDescriptors, virtualSize: virtualSize)
    guard nvram == nil || nvram?.mediaType == RunnerVMMediaType.nvram(for: config.metadata.os) else {
      throw RegistryError.unsupportedManifest(
        reason: "NVRAM layer type does not match a \(config.metadata.os.rawValue) guest"
      )
    }
    if let nvram { try limits.validate(nvram: nvram) }
    return RunnerVMArtifact(
      metadata: config.metadata, configDescriptor: manifest.config, diskChunks: chunks, nvram: nvram,
      diskVirtualSize: virtualSize, diskContentDigest: contentDigest,
      createdAt: manifest.annotation(RunnerVMAnnotation.created).flatMap(Self.parseTimestamp)
    )
  }

  /// Assembles the manifest a push publishes.
  public static func makeManifest(
    config: OCIDescriptor, diskChunks: [OCIDescriptor], nvram: OCIDescriptor?,
    diskVirtualSize: UInt64, diskContentDigest: String, createdAt: Date
  ) -> OCIManifest {
    OCIManifest(
      artifactType: RunnerVMMediaType.artifact, config: config,
      layers: diskChunks + [nvram].compactMap(\.self),
      annotations: [
        RunnerVMAnnotation.diskVirtualSize: String(diskVirtualSize),
        RunnerVMAnnotation.diskContentDigest: diskContentDigest,
        RunnerVMAnnotation.created: ISO8601DateFormatter().string(from: createdAt),
      ]
    )
  }

  private static func validateChunkOrder(_ chunks: [OCIDescriptor]) throws {
    for (position, chunk) in chunks.enumerated() {
      let declared = try chunk.requiredAnnotation(RunnerVMAnnotation.chunkIndex)
      guard Int(declared) == position else {
        throw RegistryError.unsupportedManifest(
          reason: "chunk at position \(position) declares index \(declared)"
        )
      }
      _ = try chunk.requiredUInt64Annotation(RunnerVMAnnotation.chunkUncompressedSize)
      _ = try chunk.requiredAnnotation(RunnerVMAnnotation.chunkUncompressedDigest)
    }
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
  }
}
