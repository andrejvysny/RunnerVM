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
    public init(docker: Bool = false, ssh: Bool = false) {
      self.docker = docker
      self.ssh = ssh
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

  public init(
    schemaVersion: Int = ImageMetadata.currentSchemaVersion, os: GuestOS, architecture: String = "arm64",
    diskFormat: DiskFormat = .raw, virtualDiskSizeBytes: UInt64, runnerVersion: String? = nil,
    guestAgentVersion: String? = nil, minimumHostOS: String = "15.0", createdAt: Date, boot: Boot,
    macos: MacOSPlatform? = nil, capabilities: Capabilities = Capabilities()
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
  }
}
