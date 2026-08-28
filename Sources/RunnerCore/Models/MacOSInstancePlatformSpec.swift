import Foundation

/// The macOS platform facts one instance's `spec.json` carries over to vmworker.
///
/// A copy of `ImageMetadata.MacOSPlatform` rather than a reference to it: `spec.json` is the
/// worker's whole world, and the image's `metadata.json` is not readable from inside an instance
/// directory. Every field is opaque to runnerd -- `hardwareModel` is base64 that only vmworker
/// hands to `VZMacHardwareModel(dataRepresentation:)` -- so the daemon never links Virtualization
/// to move it around.
///
/// Instance identity (the machine identifier and the MAC address) is deliberately *not* here: it
/// belongs to one instance, not to the image, and lives in files under the instance directory
/// (`machine-identifier.bin`) or in its own spec field (`macAddress`).
public struct MacOSInstancePlatformSpec: Codable, Sendable, Equatable {
  /// Base64 of `VZMacHardwareModel.dataRepresentation`.
  public var hardwareModel: String
  public var sourceVersion: String?
  /// Sizing floors from the image, carried so a failure is diagnosable from `spec.json` alone.
  public var minimumCPUCount: Int?
  public var minimumMemoryBytes: UInt64?

  public init(
    hardwareModel: String, sourceVersion: String? = nil, minimumCPUCount: Int? = nil,
    minimumMemoryBytes: UInt64? = nil
  ) {
    self.hardwareModel = hardwareModel
    self.sourceVersion = sourceVersion
    self.minimumCPUCount = minimumCPUCount
    self.minimumMemoryBytes = minimumMemoryBytes
  }

  public init(_ platform: ImageMetadata.MacOSPlatform) {
    self.init(
      hardwareModel: platform.hardwareModel, sourceVersion: platform.sourceVersion,
      minimumCPUCount: platform.minimumCPUCount, minimumMemoryBytes: platform.minimumMemoryBytes)
  }
}
