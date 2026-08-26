// Derived from openai/tart@16d186c Sources/tart/Platform/Linux.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import Virtualization

/// Linux guest: EFI boot loader + per-instance EFI variable store + generic platform (spec §26).
public struct LinuxVMPlatform: VMPlatformBuilder {
  public init() {}

  public func bootLoader(paths: VMRuntimePaths) throws -> VZBootLoader {
    let loader = VZEFIBootLoader()
    loader.variableStore = VZEFIVariableStore(url: paths.nvram)
    return loader
  }

  public func platform(paths: VMRuntimePaths) throws -> VZPlatformConfiguration {
    // Nested virtualization intentionally left disabled (spec §26).
    VZGenericPlatformConfiguration()
  }

  public func graphicsDevices() -> [VZGraphicsDeviceConfiguration] { [] }

  /// `.cached` avoids guest filesystem corruption observed with the default mode (tart PR #675).
  public var diskCachingMode: VZDiskImageCachingMode { .cached }

  /// Creates an empty EFI variable store. Called once per instance at clone time.
  public static func createVariableStore(at url: URL) throws {
    _ = try VZEFIVariableStore(creatingVariableStoreAt: url)
  }
}
