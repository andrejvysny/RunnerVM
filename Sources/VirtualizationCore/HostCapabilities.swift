import Foundation
import RunnerCore
import Virtualization

/// Host-side facts runnerd needs for scheduling/validation. Produced only by `vmworker probe`
/// so that runnerd never links Virtualization.framework (spec §7.2, plan A1-10).
public struct HostCapabilities: Codable, Sendable, Equatable {
  public var virtualizationSupported: Bool
  public var architecture: String
  public var hostOSVersion: String
  public var logicalCPUCount: Int
  public var physicalMemoryBytes: UInt64
  public var minimumAllowedCPUCount: Int
  public var maximumAllowedCPUCount: Int
  public var minimumAllowedMemoryBytes: UInt64
  public var maximumAllowedMemoryBytes: UInt64
  public var nestedVirtualizationSupported: Bool
  public var macOSGuestLimit: Int

  public static func probe() -> HostCapabilities {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var nested = false
    if #available(macOS 15, *) {
      nested = VZGenericPlatformConfiguration.isNestedVirtualizationSupported
    }
    return HostCapabilities(
      virtualizationSupported: VZVirtualMachine.isSupported,
      architecture: Self.machineArchitecture(),
      hostOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      minimumAllowedCPUCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      maximumAllowedCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      minimumAllowedMemoryBytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      maximumAllowedMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize,
      nestedVirtualizationSupported: nested,
      macOSGuestLimit: HostConstants.macOSGuestLimit
    )
  }

  private static func machineArchitecture() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    return String(cString: buffer)
  }
}
