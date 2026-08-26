// Derived from openai/tart@16d186c Sources/tart/VM.swift (craftConfiguration) — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore
import Virtualization

public enum VMConfigurationError: Error, CustomStringConvertible {
  case invalidMACAddress(String)
  case unsupportedGuestOS(GuestOS)

  public var description: String {
    switch self {
    case .invalidMACAddress(let mac): "invalid MAC address: \(mac)"
    case .unsupportedGuestOS(let os): "guest OS not supported yet: \(os.rawValue)"
    }
  }
}

/// Builds a headless, CI-oriented VZVirtualMachineConfiguration (spec §27/§28).
/// Inputs: spec + paths. No GitHub/SQLite/OCI knowledge.
public struct VMConfigurationBuilder {
  public var spec: VMInstanceSpec
  public var paths: VMRuntimePaths
  /// Extra read-only block devices (e.g. cloud-init seed). Empty for runner instances.
  public var readOnlyDisks: [URL]

  public init(spec: VMInstanceSpec, paths: VMRuntimePaths, readOnlyDisks: [URL] = []) {
    self.spec = spec
    self.paths = paths
    self.readOnlyDisks = readOnlyDisks
  }

  public static func platform(for os: GuestOS) throws -> any VMPlatformBuilder {
    switch os {
    case .linux: LinuxVMPlatform()
    case .macos: throw VMConfigurationError.unsupportedGuestOS(os)
    }
  }

  /// `validate` calls `VZVirtualMachineConfiguration.validate()`, which itself requires the
  /// virtualization entitlement — so it only works inside signed vmworker, not in test runners.
  public func build(validate: Bool = true) throws -> VZVirtualMachineConfiguration {
    let platform = try Self.platform(for: spec.os)
    let config = VZVirtualMachineConfiguration()

    config.bootLoader = try platform.bootLoader(paths: paths)
    config.cpuCount = spec.cpuCount
    config.memorySize = spec.memoryBytes
    config.platform = try platform.platform(paths: paths)
    config.graphicsDevices = platform.graphicsDevices()

    guard let mac = VZMACAddress(string: spec.macAddress) else {
      throw VMConfigurationError.invalidMACAddress(spec.macAddress)
    }
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = mac
    config.networkDevices = [net]

    var storage: [VZStorageDeviceConfiguration] = []
    let root = try VZDiskImageStorageDeviceAttachment(
      url: paths.disk, readOnly: false, cachingMode: platform.diskCachingMode, synchronizationMode: .full
    )
    storage.append(VZVirtioBlockDeviceConfiguration(attachment: root))
    for url in readOnlyDisks {
      let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
      storage.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
    }
    config.storageDevices = storage

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

    if spec.serialConsole {
      FileManager.default.createFile(atPath: paths.serialLog.path, contents: nil)
      let handle = try FileHandle(forWritingTo: paths.serialLog)
      let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
      serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
      config.serialPorts = [serial]
    }

    // Deliberately absent: audio, keyboard, pointing devices, clipboard, directory shares, GUI.
    if validate { try config.validate() }
    return config
  }
}
