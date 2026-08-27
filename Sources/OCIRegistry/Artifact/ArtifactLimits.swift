import Foundation

/// Bounds on what a RunnerVM manifest and its blobs are allowed to declare, checked before any
/// disk bytes move.
///
/// A registry is not a trusted party the moment RunnerVM pulls from anywhere other than its own
/// push: a manifest is attacker-controlled input. Without these checks a crafted manifest could
/// make this host allocate memory or disk proportional to a forged size field.
public struct ArtifactLimits: Sendable, Equatable {
  public var maxLayers: Int
  public var maxConfigBytes: Int64
  public var maxNVRAMBytes: Int64
  public var maxVirtualDiskBytes: UInt64

  public static let `default` = ArtifactLimits()

  public init(
    maxLayers: Int = 4096, maxConfigBytes: Int64 = 1 << 20, maxNVRAMBytes: Int64 = 128 << 20,
    maxVirtualDiskBytes: UInt64 = 512 << 30
  ) {
    self.maxLayers = maxLayers
    self.maxConfigBytes = maxConfigBytes
    self.maxNVRAMBytes = maxNVRAMBytes
    self.maxVirtualDiskBytes = maxVirtualDiskBytes
  }

  /// Structural bounds only -- no layer blob has been fetched yet. `RunnerVMArtifact.layout(of:)`
  /// calls this before anything else it does.
  public func validate(manifest: OCIManifest) throws {
    guard manifest.layers.count <= maxLayers else {
      throw RegistryError.unsupportedManifest(
        reason: "manifest has \(manifest.layers.count) layers, over the \(maxLayers)-layer limit"
      )
    }
    try Self.validateDescriptor(manifest.config)
    guard manifest.config.size <= maxConfigBytes else {
      throw RegistryError.unsupportedManifest(
        reason: "config blob declares \(manifest.config.size) bytes, over the \(maxConfigBytes)-byte limit"
      )
    }
    for layer in manifest.layers {
      try Self.validateDescriptor(layer)
    }
  }

  /// `size` must fall in `0...maxNVRAMBytes`: negative is nonsensical, and zero is legal (an empty
  /// EFI variable store).
  public func validate(nvram descriptor: OCIDescriptor) throws {
    try Self.validateDescriptor(descriptor)
    guard (0...maxNVRAMBytes).contains(descriptor.size) else {
      throw RegistryError.unsupportedManifest(
        reason: "NVRAM layer declares \(descriptor.size) bytes, outside 0...\(maxNVRAMBytes)"
      )
    }
  }

  public func validate(virtualDiskBytes: UInt64) throws {
    guard virtualDiskBytes <= maxVirtualDiskBytes else {
      throw RegistryError.unsupportedManifest(
        reason: "virtual disk declares \(virtualDiskBytes) bytes, over the \(maxVirtualDiskBytes)-byte limit"
      )
    }
  }

  private static func validateDescriptor(_ descriptor: OCIDescriptor) throws {
    guard descriptor.size >= 0 else {
      throw RegistryError.unsupportedManifest(
        reason: "descriptor \(descriptor.digest) declares a negative size \(descriptor.size)"
      )
    }
    guard isWellFormedDigest(descriptor.digest) else {
      throw RegistryError.unsupportedManifest(
        reason: "descriptor digest '\(descriptor.digest)' is not sha256:<64 lowercase hex>"
      )
    }
  }

  /// Same grammar `ImageDigest.sha256Hex` checks: `sha256:` followed by exactly 64 lowercase hex
  /// characters.
  private static func isWellFormedDigest(_ digest: String) -> Bool {
    let prefix = "sha256:"
    guard digest.hasPrefix(prefix) else { return false }
    let hex = digest.dropFirst(prefix.count)
    return hex.count == 64 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}
