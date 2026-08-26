import Foundation
import RunnerCore

/// The local, non-OCI manifest written as `images/manifests/sha256-<hex>/manifest.json` (spec §22).
///
/// It is deliberately not an OCI manifest: RunnerVM's local identity must stay stable even when the
/// same content is pushed to two registries that assign different blob digests (spec §21).
public struct LocalImageManifest: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public enum LayerRole: String, Codable, Sendable, CaseIterable, Comparable {
    /// The raw sparse root disk.
    case disk
    /// Linux EFI variable store, or macOS auxiliary storage.
    case nvram

    public static func < (lhs: LayerRole, rhs: LayerRole) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public struct Layer: Codable, Sendable, Equatable {
    public var role: LayerRole
    /// `sha256:<hex>` of the blob's bytes; also its path under `images/blobs/`.
    public var digest: String
    /// Logical size, not allocation: a sparse 80 GiB disk reports 80 GiB here.
    public var sizeBytes: UInt64

    public init(role: LayerRole, digest: String, sizeBytes: UInt64) {
      self.role = role
      self.digest = digest
      self.sizeBytes = sizeBytes
    }
  }

  public var schemaVersion: Int
  public var digest: ImageDigest
  public var os: GuestOS
  public var layers: [Layer]
  /// `sha256:<hex>` of the sibling `metadata.json` bytes.
  public var metadataDigest: String
  /// Human alias. Excluded from `digest`, because two imports of identical content under different
  /// names are the same image; published manifests are immutable, so the first name wins.
  public var name: String?

  public init(
    schemaVersion: Int = LocalImageManifest.currentSchemaVersion, digest: ImageDigest, os: GuestOS,
    layers: [Layer], metadataDigest: String, name: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.digest = digest
    self.os = os
    self.layers = layers
    self.metadataDigest = metadataDigest
    self.name = name
  }

  public func layer(_ role: LayerRole) -> Layer? {
    layers.first { $0.role == role }
  }

  // MARK: - Identity

  /// Exactly the fields that make two images interchangeable. `digest` itself and `name` are left
  /// out: the former is the output, the latter is a local label.
  private struct Identity: Encodable {
    let layers: [Layer]
    let metadataDigest: String
    let os: GuestOS
    let schemaVersion: Int
  }

  static func computeDigest(
    os: GuestOS, layers: [Layer], metadataDigest: String,
    schemaVersion: Int = LocalImageManifest.currentSchemaVersion
  ) throws -> ImageDigest {
    let identity = Identity(
      layers: layers.sorted { $0.role < $1.role }, metadataDigest: metadataDigest,
      os: os, schemaVersion: schemaVersion
    )
    return ImageDigest(rawValue: SHA256Hasher.hash(try CanonicalJSON.encode(identity)))
  }
}

extension ImageDigest {
  /// Hex body of a `sha256:<64 hex>` digest, or nil when the string is not one.
  var sha256Hex: String? {
    let prefix = "sha256:"
    guard rawValue.hasPrefix(prefix) else { return nil }
    let hex = String(rawValue.dropFirst(prefix.count))
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    return hex
  }

  /// `sha256-<hex>`: the manifest directory name. `:` is legal on APFS but hostile in shell paths.
  var manifestDirectoryName: String? {
    sha256Hex.map { "sha256-\($0)" }
  }

  static func fromManifestDirectoryName(_ name: String) -> ImageDigest? {
    guard name.hasPrefix("sha256-") else { return nil }
    let candidate = ImageDigest(rawValue: "sha256:" + name.dropFirst("sha256-".count))
    return candidate.sha256Hex == nil ? nil : candidate
  }
}
