// Derived from openai/tart@16d186c Sources/tart/VMConfig.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore

/// Tart's `config.json`, as it is published in the `application/vnd.cirruslabs.tart.config.v1`
/// layer (spec §58).
///
/// This is a *reader* only: RunnerVM never writes this shape. Tart's own decoder builds
/// `Virtualization` objects (`VZMACAddress`, `VZMacHardwareModel`) while decoding; here every field
/// stays a plain value, because importing an image must not depend on what this host's
/// Virtualization framework happens to accept.
public struct TartVMConfig: Decodable, Sendable, Equatable {
  /// Absent means `darwin`, matching tart's own decoder — a config written before the field
  /// existed could only have been a macOS VM.
  public enum OS: String, Decodable, Sendable { case darwin, linux }
  /// Absent means `arm64`, matching tart.
  public enum Architecture: String, Decodable, Sendable { case arm64, amd64 }

  /// Absent means `raw`. Deliberate deviation from tart: tart maps an *unknown* string to `raw`
  /// (`DiskImageFormat(rawValue:) ?? .raw`), which would make RunnerVM silently treat some future
  /// non-raw format as a raw disk and reassemble garbage. An unknown value is refused instead.
  public enum DiskFormat: String, Decodable, Sendable { case raw, asif }

  public struct Display: Decodable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `pt` or `px`; carried verbatim because RunnerVM does not interpret it.
    public var unit: String?

    public init(width: Int = 1024, height: Int = 768, unit: String? = nil) {
      self.width = width
      self.height = height
      self.unit = unit
    }

    /// Spelled out because the custom initializer below suppresses synthesis, and the enclosing
    /// type's own `CodingKeys` would otherwise be picked up instead.
    private enum DisplayKeys: String, CodingKey { case width, height, unit }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: DisplayKeys.self)
      width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1024
      height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 768
      unit = try container.decodeIfPresent(String.self, forKey: .unit)
    }
  }

  public var version: Int
  public var os: OS
  public var arch: Architecture
  public var cpuCountMin: Int
  public var cpuCount: Int
  public var memorySizeMin: UInt64
  public var memorySize: UInt64
  /// Validated here and then discarded: a MAC address is instance identity, and spec §24 forbids
  /// it in `ImageMetadata`. It is decoded only so a malformed config is caught at import.
  public var macAddress: String
  public var display: Display?
  public var displayRefit: Bool?
  public var diskFormat: DiskFormat
  /// macOS only, base64 of `VZMacMachineIdentifier.dataRepresentation`. Instance identity —
  /// discarded, never carried into `ImageMetadata`.
  public var ecid: String?
  /// macOS only, base64 of `VZMacHardwareModel.dataRepresentation`. This one *is* image identity:
  /// a macOS guest cannot boot without it.
  public var hardwareModel: String?

  private enum CodingKeys: String, CodingKey {
    case version, os, arch, cpuCountMin, cpuCount, memorySizeMin, memorySize, macAddress
    case display, displayRefit, diskFormat, ecid, hardwareModel
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    os = try container.decodeIfPresent(OS.self, forKey: .os) ?? .darwin
    arch = try container.decodeIfPresent(Architecture.self, forKey: .arch) ?? .arm64
    cpuCountMin = try container.decode(Int.self, forKey: .cpuCountMin)
    cpuCount = try container.decode(Int.self, forKey: .cpuCount)
    memorySizeMin = try container.decode(UInt64.self, forKey: .memorySizeMin)
    memorySize = try container.decode(UInt64.self, forKey: .memorySize)
    macAddress = try container.decode(String.self, forKey: .macAddress)
    guard Self.isWellFormedMAC(macAddress) else {
      throw DecodingError.dataCorruptedError(
        forKey: .macAddress, in: container,
        debugDescription: "'\(macAddress)' is not xx:xx:xx:xx:xx:xx"
      )
    }
    display = try container.decodeIfPresent(Display.self, forKey: .display)
    displayRefit = try container.decodeIfPresent(Bool.self, forKey: .displayRefit)
    diskFormat = try container.decodeIfPresent(DiskFormat.self, forKey: .diskFormat) ?? .raw
    ecid = try container.decodeIfPresent(String.self, forKey: .ecid)
    hardwareModel = try container.decodeIfPresent(String.self, forKey: .hardwareModel)
  }

  public static func decode(_ data: Data) throws -> TartVMConfig {
    do {
      return try JSONDecoder().decode(TartVMConfig.self, from: data)
    } catch {
      throw RegistryError.unsupportedManifest(reason: "tart config blob is not a VM config: \(error)")
    }
  }

  /// Six colon-separated pairs of hex digits, which is what `VZMACAddress(string:)` accepts.
  static func isWellFormedMAC(_ text: String) -> Bool {
    let groups = text.split(separator: ":", omittingEmptySubsequences: false)
    guard groups.count == 6 else { return false }
    return groups.allSatisfy { group in
      group.count == 2 && group.allSatisfy(\.isHexDigit)
    }
  }
}

/// The stub OCI image config tart pushes for Docker Hub compatibility. It repeats the guest OS and
/// architecture and carries the disk format as a label, so both are cross-checked against the
/// tart config layer rather than trusted from one place (spec §58).
public struct TartOCIConfig: Decodable, Sendable, Equatable {
  public struct ConfigContainer: Decodable, Sendable, Equatable {
    public var labels: [String: String]?

    /// Capitalised on the wire: this is Docker's image-config schema, which tart mirrors.
    private enum CodingKeys: String, CodingKey { case labels = "Labels" }
  }

  public var architecture: String
  public var os: String
  public var config: ConfigContainer?

  public var diskFormatLabel: String? {
    config?.labels?[TartAnnotation.diskFormatLabel]
  }

  public static func decode(_ data: Data) throws -> TartOCIConfig {
    do {
      return try JSONDecoder().decode(TartOCIConfig.self, from: data)
    } catch {
      throw RegistryError.unsupportedManifest(reason: "OCI config blob is not a tart image config: \(error)")
    }
  }
}

extension TartVMConfig {
  /// Everything RunnerVM keeps from a tart image, and nothing more.
  ///
  /// `ecid`, `macAddress` and `displayRefit` are deliberately dropped: the first two are instance
  /// identity (spec §24 keeps them out of image metadata) and the third is a desktop nicety with
  /// no meaning for a headless runner. The sizing hints survive in `provenance.imported.tartConfig`
  /// so the original resource intent is recoverable.
  public func imageMetadata(
    ociConfig: TartOCIConfig, virtualDiskSizeBytes: UInt64, createdAt: Date,
    provenance: ImageMetadata.Provenance
  ) throws -> ImageMetadata {
    try validate(against: ociConfig)
    return ImageMetadata(
      os: os == .darwin ? .macos : .linux,
      architecture: Architecture.arm64.rawValue,
      diskFormat: .raw,
      virtualDiskSizeBytes: virtualDiskSizeBytes,
      // Nothing in a tart image is a RunnerVM runner or agent, and claiming otherwise here is
      // what `hasGuestAgent` would read as "this can run jobs".
      runnerVersion: nil,
      guestAgentVersion: nil,
      minimumHostOS: "15.0",
      createdAt: createdAt,
      boot: ImageMetadata.Boot(type: os == .darwin ? .macos : .efi),
      macos: os == .darwin ? hardwareModel.map { ImageMetadata.MacOSPlatform(hardwareModel: $0) } : nil,
      capabilities: ImageMetadata.Capabilities(docker: false, ssh: true, guestAgent: false),
      provenance: provenance
    )
  }

  /// The sizing hints worth carrying forward, plus where the image came from.
  public func provenance(manifestDigest: String) -> ImageMetadata.Provenance {
    ImageMetadata.Provenance(
      imported: ImageMetadata.Provenance.Imported(
        format: ImageArtifactFormat.tart.rawValue,
        manifestDigest: manifestDigest,
        tartConfig: ImageMetadata.Provenance.TartConfig(
          version: version, cpuCount: cpuCount, cpuCountMin: cpuCountMin,
          memorySize: memorySize, memorySizeMin: memorySizeMin,
          displayWidth: display?.width, displayHeight: display?.height,
          diskFormat: diskFormat.rawValue
        )
      )
    )
  }

  /// Rules C3–C8: everything that has to agree between the two config blobs before the image can
  /// be called importable. All of it runs before a single disk chunk is fetched.
  private func validate(against ociConfig: TartOCIConfig) throws {
    guard version == 1 else {
      throw RegistryError.unsupportedManifest(reason: "tart config version \(version) is not supported")
    }
    guard arch == .arm64, ociConfig.architecture == Architecture.arm64.rawValue else {
      throw RegistryError.unsupportedManifest(
        reason: "image is \(arch.rawValue)/\(ociConfig.architecture); Apple Virtualization is arm64-only"
      )
    }
    guard diskFormat == .raw, [nil, "raw"].contains(ociConfig.diskFormatLabel) else {
      throw RegistryError.unsupportedManifest(
        reason: "disk format is \(ociConfig.diskFormatLabel ?? diskFormat.rawValue); "
          + "only raw tart disks can be imported"
      )
    }
    guard ociConfig.os == os.rawValue else {
      throw RegistryError.unsupportedManifest(
        reason: "tart config says \(os.rawValue) but the OCI config says \(ociConfig.os)"
      )
    }
    try validateHardwareModel()
  }

  /// A macOS guest cannot boot without its hardware model; a Linux one must not carry a stale
  /// macOS platform block into `ImageMetadata.macos`.
  private func validateHardwareModel() throws {
    switch os {
    case .darwin:
      guard let hardwareModel, Data(base64Encoded: hardwareModel) != nil else {
        throw RegistryError.unsupportedManifest(
          reason: "darwin tart config has no base64 hardwareModel"
        )
      }
    case .linux:
      guard hardwareModel == nil else {
        throw RegistryError.unsupportedManifest(
          reason: "linux tart config carries a macOS hardwareModel"
        )
      }
    }
  }
}
