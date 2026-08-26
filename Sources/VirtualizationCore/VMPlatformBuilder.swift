import Virtualization

/// Guest-OS-specific parts of a VM configuration. Implemented by LinuxVMPlatform and (M8) MacVMPlatform.
public protocol VMPlatformBuilder: Sendable {
  func bootLoader(paths: VMRuntimePaths) throws -> VZBootLoader
  func platform(paths: VMRuntimePaths) throws -> VZPlatformConfiguration
  func graphicsDevices() -> [VZGraphicsDeviceConfiguration]
  var diskCachingMode: VZDiskImageCachingMode { get }
}
