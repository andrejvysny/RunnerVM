import CryptoKit
import Foundation
import RunnerCore

/// OCI content descriptor (image-spec v1.1). `platform`/`artifactType` are only populated on index
/// entries; they encode away when nil.
public struct OCIDescriptor: Codable, Sendable, Hashable {
  public var mediaType: String
  public var digest: String
  public var size: Int64
  public var annotations: [String: String]?
  public var artifactType: String?
  public var platform: OCIPlatform?

  public init(
    mediaType: String, digest: String, size: Int64, annotations: [String: String]? = nil,
    artifactType: String? = nil, platform: OCIPlatform? = nil
  ) {
    self.mediaType = mediaType
    self.digest = digest
    self.size = size
    self.annotations = annotations?.isEmpty == true ? nil : annotations
    self.artifactType = artifactType
    self.platform = platform
  }

  public func annotation(_ key: String) -> String? {
    annotations?[key]
  }

  func requiredAnnotation(_ key: String) throws -> String {
    guard let value = annotations?[key] else {
      throw RegistryError.unsupportedManifest(reason: "layer \(digest) is missing annotation \(key)")
    }
    return value
  }

  func requiredUInt64Annotation(_ key: String) throws -> UInt64 {
    guard let value = try UInt64(requiredAnnotation(key)) else {
      throw RegistryError.unsupportedManifest(reason: "annotation \(key) on \(digest) is not a number")
    }
    return value
  }
}

public struct OCIPlatform: Codable, Sendable, Hashable {
  public var architecture: String
  public var os: String
  public var variant: String?

  public init(architecture: String, os: String, variant: String? = nil) {
    self.architecture = architecture
    self.os = os
    self.variant = variant
  }
}

public struct OCIManifest: Codable, Sendable, Hashable {
  public var schemaVersion: Int
  public var mediaType: String
  public var artifactType: String?
  public var config: OCIDescriptor
  public var layers: [OCIDescriptor]
  public var annotations: [String: String]?

  public init(
    schemaVersion: Int = 2, mediaType: String = RunnerVMMediaType.ociManifest,
    artifactType: String? = nil, config: OCIDescriptor, layers: [OCIDescriptor],
    annotations: [String: String]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.mediaType = mediaType
    self.artifactType = artifactType
    self.config = config
    self.layers = layers
    self.annotations = annotations?.isEmpty == true ? nil : annotations
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, mediaType, artifactType, config, layers, annotations
  }

  /// Tolerant of a registry that omits `mediaType` in the body; `RegistryClient` then falls back to
  /// the `Content-Type` header to tell a manifest from an index.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
      ?? RunnerVMMediaType.ociManifest
    artifactType = try container.decodeIfPresent(String.self, forKey: .artifactType)
    config = try container.decode(OCIDescriptor.self, forKey: .config)
    layers = try container.decode([OCIDescriptor].self, forKey: .layers)
    annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations)
  }

  public func annotation(_ key: String) -> String? {
    annotations?[key]
  }

  /// The exact bytes pushed. Encoding is deterministic (sorted keys, unescaped slashes), so pushing
  /// the same logical manifest twice yields the same digest and the registry deduplicates it.
  public func encoded() throws -> Data {
    try OCIJSON.encode(self)
  }

  public static func decode(_ data: Data) throws -> OCIManifest {
    do {
      return try OCIJSON.decode(OCIManifest.self, from: data)
    } catch {
      throw RegistryError.invalidResponse(operation: "manifest", reason: "\(error)")
    }
  }
}

/// A multi-platform index. RunnerVM reads these (a registry may front several architectures behind
/// one tag) but only ever publishes single manifests.
public struct OCIIndex: Codable, Sendable, Hashable {
  public var schemaVersion: Int
  public var mediaType: String
  public var manifests: [OCIDescriptor]
  public var annotations: [String: String]?

  public init(
    schemaVersion: Int = 2, mediaType: String = RunnerVMMediaType.ociIndex,
    manifests: [OCIDescriptor], annotations: [String: String]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.mediaType = mediaType
    self.manifests = manifests
    self.annotations = annotations
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, mediaType, manifests, annotations
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? RunnerVMMediaType.ociIndex
    manifests = try container.decode([OCIDescriptor].self, forKey: .manifests)
    annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations)
  }

  public func encoded() throws -> Data {
    try OCIJSON.encode(self)
  }

  public static func decode(_ data: Data) throws -> OCIIndex {
    do {
      return try OCIJSON.decode(OCIIndex.self, from: data)
    } catch {
      throw RegistryError.invalidResponse(operation: "manifest index", reason: "\(error)")
    }
  }

  /// Picks the entry this host can actually run: arm64, a guest OS RunnerVM supports, and — when
  /// any entry declares one — RunnerVM's own artifact type.
  public func select(architecture: String = "arm64") throws -> OCIDescriptor {
    var candidates = manifests.filter { entry in
      guard let platform = entry.platform else { return true }
      return platform.architecture == architecture
        && ["darwin", "linux"].contains(platform.os)
    }
    if candidates.contains(where: { $0.artifactType == RunnerVMMediaType.artifact }) {
      candidates = candidates.filter { $0.artifactType == RunnerVMMediaType.artifact }
    }
    guard let selected = candidates.first else {
      throw RegistryError.unsupportedManifest(
        reason: "index has no \(architecture) RunnerVM manifest"
      )
    }
    return selected
  }
}

/// Deterministic JSON for everything this module signs by digest.
enum OCIJSON {
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }

  static func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
