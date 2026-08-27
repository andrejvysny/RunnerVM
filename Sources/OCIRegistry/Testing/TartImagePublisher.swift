// Derived from openai/tart@16d186c Sources/tart/VMDirectory+OCI.swift:156-205 (push layout:
// config layer, disk chunks, NVRAM, stub OCI config) — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore

/// Publishes a tart-shaped image into a `FakeRegistry`, so the importer is exercised against the
/// bytes tart itself would push rather than against a hand-written fixture.
///
/// Test support shipped in the product module for the same reason `FakeRegistry` is: SwiftPM test
/// targets cannot import each other. Nothing in the daemon may call it — RunnerVM never publishes
/// tart images (spec §58).
public enum TartImagePublisher {
  public struct Published: Sendable {
    public let reference: OCIReference
    public let manifestDigest: ImageDigest
    /// Compressed disk-chunk blob digests, in disk order.
    public let chunkDigests: [String]
    public let vmConfigDigest: String
    public let ociConfigDigest: String
    public let nvramDigest: String
    public let virtualBytes: UInt64
  }

  /// - Parameter vmConfigOverrides: merged into the generated `config.json`. `NSNull()` removes a
  ///   key, which is how a test builds a config that is missing a required field.
  /// - Parameter includeUncompressedDiskSizeAnnotation: `false` publishes a manifest without
  ///   `org.cirruslabs.tart.uncompressed-disk-size`, which tart's own writer also allows.
  public static func publish(
    into fake: FakeRegistry, diskURL: URL, nvramURL: URL, staging: URL,
    repository: String = "cirruslabs/ubuntu", tag: String = "latest", os: String = "linux",
    architecture: String = "arm64", diskFormat: String = "raw", chunkBytes: Int = 8 << 20,
    uploadTime: Date? = nil, vmConfigOverrides: [String: Any] = [:],
    includeUncompressedDiskSizeAnnotation: Bool = true
  ) throws -> Published {
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let virtualBytes = try DiskLayerizer.fileSize(of: diskURL)
    let chunks = try chunkLayers(
      into: fake, diskURL: diskURL, staging: staging, virtualBytes: virtualBytes,
      chunkBytes: chunkBytes
    )
    let nvramData = try Data(contentsOf: nvramURL)
    let nvramDigest = fake.putBlob(nvramData)
    let vmConfig = try blob(
      into: fake, object: vmConfigObject(
        os: os, architecture: architecture, diskFormat: diskFormat, overrides: vmConfigOverrides
      )
    )
    let ociConfig = try blob(
      into: fake, object: ociConfigObject(os: os, architecture: architecture, diskFormat: diskFormat)
    )
    var annotations: [String: String] = [:]
    if includeUncompressedDiskSizeAnnotation {
      annotations[TartAnnotation.uncompressedDiskSize] = String(virtualBytes)
    }
    if let uploadTime {
      annotations[TartAnnotation.uploadTime] = ISO8601DateFormatter().string(from: uploadTime)
    }
    let published = try putManifest(
      [descriptor(TartMediaType.config, vmConfig)] + chunks
        + [descriptor(TartMediaType.nvram, (nvramDigest, nvramData.count))],
      config: descriptor(TartMediaType.ociConfig, ociConfig), annotations: annotations,
      into: fake, repository: repository, tag: tag
    )
    return Published(
      reference: published.reference, manifestDigest: published.digest,
      chunkDigests: chunks.map(\.digest), vmConfigDigest: vmConfig.digest,
      ociConfigDigest: ociConfig.digest, nvramDigest: nvramDigest, virtualBytes: virtualBytes
    )
  }

  /// Stores an arbitrary manifest, so a test can publish one that no correct writer would produce.
  @discardableResult
  public static func putManifest(
    _ layers: [OCIDescriptor], config: OCIDescriptor, annotations: [String: String]? = nil,
    into fake: FakeRegistry, repository: String, tag: String, schemaVersion: Int = 2,
    mediaType: String = RunnerVMMediaType.ociManifest, artifactType: String? = nil
  ) throws -> (reference: OCIReference, digest: ImageDigest, manifest: OCIManifest) {
    let manifest = OCIManifest(
      schemaVersion: schemaVersion, mediaType: mediaType, artifactType: artifactType,
      config: config, layers: layers, annotations: annotations
    )
    let digest = fake.putManifest(
      try manifest.encoded(), repository: repository, reference: tag, mediaType: mediaType
    )
    return (
      try fake.reference(repository, tag: tag), ImageDigest(rawValue: digest), manifest
    )
  }

  // MARK: - Pieces

  /// One independently decompressible LZ4 stream per ≤`chunkBytes` slice, annotated exactly the
  /// way tart annotates `disk.v2` layers.
  private static func chunkLayers(
    into fake: FakeRegistry, diskURL: URL, staging: URL, virtualBytes: UInt64, chunkBytes: Int
  ) throws -> [OCIDescriptor] {
    var layers: [OCIDescriptor] = []
    for (index, span) in DiskLayerizer.chunkPlan(
      virtualSize: virtualBytes, chunkBytes: chunkBytes
    ).enumerated() {
      let compressedURL = staging.appending(path: "tart-chunk-\(index).lz4")
      defer { try? FileManager.default.removeItem(at: compressedURL) }
      let chunk = try LZ4Codec.compressChunk(
        source: diskURL, offset: span.offset, length: span.length, to: compressedURL
      )
      fake.putBlob(try Data(contentsOf: compressedURL))
      layers.append(
        OCIDescriptor(
          mediaType: TartMediaType.diskV2, digest: chunk.compressedDigest,
          size: Int64(chunk.compressedSize),
          annotations: [
            TartAnnotation.uncompressedSize: String(chunk.uncompressedSize),
            TartAnnotation.uncompressedContentDigest: chunk.uncompressedDigest,
          ]
        )
      )
    }
    return layers
  }

  private static func vmConfigObject(
    os: String, architecture: String, diskFormat: String, overrides: [String: Any]
  ) -> [String: Any] {
    var object: [String: Any] = [
      "version": 1, "os": os, "arch": architecture,
      "cpuCountMin": 4, "cpuCount": 4,
      "memorySizeMin": 4_294_967_296, "memorySize": 4_294_967_296,
      "diskFormat": diskFormat,
      "display": ["width": 1024, "height": 768],
      "macAddress": "6a:3e:f1:99:18:c1",
    ]
    if os == "darwin" {
      object["hardwareModel"] = Data("fake-hardware-model".utf8).base64EncodedString()
      object["ecid"] = Data("fake-ecid".utf8).base64EncodedString()
    }
    for (key, value) in overrides {
      if value is NSNull { object[key] = nil } else { object[key] = value }
    }
    return object
  }

  private static func ociConfigObject(
    os: String, architecture: String, diskFormat: String
  ) -> [String: Any] {
    [
      "architecture": architecture, "os": os,
      "config": ["Labels": [TartAnnotation.diskFormatLabel: diskFormat]],
    ]
  }

  private static func blob(
    into fake: FakeRegistry, object: [String: Any]
  ) throws -> (digest: String, size: Int) {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return (fake.putBlob(data), data.count)
  }

  private static func descriptor(
    _ mediaType: String, _ blob: (digest: String, size: Int)
  ) -> OCIDescriptor {
    OCIDescriptor(mediaType: mediaType, digest: blob.digest, size: Int64(blob.size))
  }
}
