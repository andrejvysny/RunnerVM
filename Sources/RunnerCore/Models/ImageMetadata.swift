import Foundation

/// Project-owned image metadata (spec §24). Stored as `metadata.json` next to the image files and in
/// `images.metadata_json`. Never contains instance identity (machine identifier, MAC).
public struct ImageMetadata: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public struct Boot: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case efi, macos }
    public var type: Kind
    public init(type: Kind) { self.type = type }
  }

  public struct MacOSPlatform: Codable, Sendable, Equatable {
    /// Base64 of `VZMacHardwareModel.dataRepresentation`.
    public var hardwareModel: String
    public var sourceVersion: String?
    public init(hardwareModel: String, sourceVersion: String? = nil) {
      self.hardwareModel = hardwareModel
      self.sourceVersion = sourceVersion
    }
  }

  public struct Capabilities: Codable, Sendable, Equatable {
    public var docker: Bool
    public var ssh: Bool
    /// Explicit record of whether this image carries the RunnerVM guest agent. `nil` on metadata
    /// sealed before this field existed; `ImageMetadata.hasGuestAgent` falls back to
    /// `guestAgentVersion` for those. Always explicit on anything imported after T7 (spec `image
    /// import --no-guest-agent`).
    public var guestAgent: Bool?
    /// Free-form labels a build or import attached to the image; RunnerVM itself does not
    /// interpret these.
    public var labels: [String: String]?

    public init(
      docker: Bool = false, ssh: Bool = false, guestAgent: Bool? = nil,
      labels: [String: String]? = nil
    ) {
      self.docker = docker
      self.ssh = ssh
      self.guestAgent = guestAgent
      self.labels = labels
    }
  }

  public enum DiskFormat: String, Codable, Sendable { case raw }

  public var schemaVersion: Int
  public var os: GuestOS
  public var architecture: String
  public var diskFormat: DiskFormat
  public var virtualDiskSizeBytes: UInt64
  public var runnerVersion: String?
  public var guestAgentVersion: String?
  public var minimumHostOS: String
  public var createdAt: Date
  public var boot: Boot
  public var macos: MacOSPlatform?
  public var capabilities: Capabilities
  /// How this image was built (see `ImageProvenance.swift`). `nil` for images sealed before
  /// provenance existed, and for anything not produced by `scripts/build-ubuntu-image.sh`.
  public var provenance: Provenance?

  public init(
    schemaVersion: Int = ImageMetadata.currentSchemaVersion, os: GuestOS, architecture: String = "arm64",
    diskFormat: DiskFormat = .raw, virtualDiskSizeBytes: UInt64, runnerVersion: String? = nil,
    guestAgentVersion: String? = nil, minimumHostOS: String = "15.0", createdAt: Date, boot: Boot,
    macos: MacOSPlatform? = nil, capabilities: Capabilities = Capabilities(),
    provenance: Provenance? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.os = os
    self.architecture = architecture
    self.diskFormat = diskFormat
    self.virtualDiskSizeBytes = virtualDiskSizeBytes
    self.runnerVersion = runnerVersion
    self.guestAgentVersion = guestAgentVersion
    self.minimumHostOS = minimumHostOS
    self.createdAt = createdAt
    self.boot = boot
    self.macos = macos
    self.capabilities = capabilities
    self.provenance = provenance
  }

  /// Whether this image carries a RunnerVM guest agent and can therefore run jobs.
  ///
  /// The explicit field wins when present. Legacy metadata with no `capabilities.guestAgent`
  /// (sealed before that field existed) is trusted only when it also recorded a guest agent
  /// version -- no build without an agent would ever have set that.
  public var hasGuestAgent: Bool {
    capabilities.guestAgent ?? (guestAgentVersion != nil)
  }
}
