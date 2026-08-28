import Foundation
import RunnerCore

/// Measured host facts. Sampling belongs to the caller; the scheduler only does arithmetic.
public struct HostResources: Sendable, Hashable {
  public var logicalCPUs: Int
  public var physicalMemoryBytes: UInt64
  public var freeDiskBytes: UInt64

  public init(logicalCPUs: Int, physicalMemoryBytes: UInt64, freeDiskBytes: UInt64) {
    self.logicalCPUs = logicalCPUs
    self.physicalMemoryBytes = physicalMemoryBytes
    self.freeDiskBytes = freeDiskBytes
  }
}

/// What the host may hand to guests after reserves and overcommit (spec §16, §17).
public struct HostBudget: Sendable, Hashable {
  /// Fractional because a cpu overcommit ratio is a `Double`; guest vCPU counts stay integral.
  public var cpuBudget: Double
  public var memoryBudgetBytes: UInt64
  /// Raw free space; the floor is subtracted at admission so both numbers stay reportable.
  public var freeDiskBytes: UInt64
  public var diskFloorBytes: UInt64
  /// Ratio applied to the post-floor disk budget (`HostConfig.Overcommit.disk`). 1.0 keeps
  /// admission fail-closed against a guest that writes every block of its disk.
  public var diskOvercommit: Double
  /// `nil` = only the resource budget bounds the VM count (`HostConfig.MaxVMs.auto`).
  public var maxVMs: Int?

  public init(
    cpuBudget: Double,
    memoryBudgetBytes: UInt64,
    freeDiskBytes: UInt64,
    diskFloorBytes: UInt64,
    maxVMs: Int?,
    diskOvercommit: Double = 1.0
  ) {
    self.cpuBudget = cpuBudget
    self.memoryBudgetBytes = memoryBudgetBytes
    self.freeDiskBytes = freeDiskBytes
    self.diskFloorBytes = diskFloorBytes
    self.maxVMs = maxVMs
    self.diskOvercommit = diskOvercommit
  }

  public init(config: HostConfig, resources: HostResources) {
    let usableCPUs = max(0, resources.logicalCPUs - max(0, config.reserve.cpu))
    let cpuRatio = max(0, config.overcommit.cpu)
    cpuBudget = Double(usableCPUs) * cpuRatio

    let usableMemory = SaturatingMath.sub(resources.physicalMemoryBytes, config.reserve.memoryBytes)
    memoryBudgetBytes = SaturatingMath.scale(usableMemory, by: config.overcommit.memory)

    freeDiskBytes = resources.freeDiskBytes
    diskFloorBytes = config.reserve.diskBytes
    diskOvercommit = max(0, config.overcommit.disk)

    switch config.maxVMs {
    case .auto: maxVMs = nil
    case let .count(n): maxVMs = max(0, n)
    }
  }

  /// Disk actually schedulable once the absolute free-space floor is honoured (spec §17), scaled
  /// by `host.overcommit.disk`.
  ///
  /// The floor is subtracted *before* the ratio deliberately: the reserve is the space macOS and
  /// the daemon's own logs need, and overcommitting into it would defeat the point of having one.
  public var diskBudgetBytes: UInt64 {
    SaturatingMath.scale(SaturatingMath.sub(freeDiskBytes, diskFloorBytes), by: diskOvercommit)
  }
}

/// UInt64 is not a ring: every capacity subtraction here can legitimately go negative, and a trap
/// in the scheduler would take the daemon down over a transient measurement.
enum SaturatingMath {
  static func sub(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    lhs > rhs ? lhs - rhs : 0
  }

  static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }

  static func scale(_ value: UInt64, by ratio: Double) -> UInt64 {
    guard ratio.isFinite, ratio > 0 else { return 0 }
    if ratio == 1 { return value }
    let scaled = (Double(value) * ratio).rounded(.down)
    guard scaled > 0 else { return 0 }
    guard scaled < Double(UInt64.max) else { return UInt64.max }
    return UInt64(scaled)
  }
}
