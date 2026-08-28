import Foundation
import RunnerCore
import Scheduler

/// How many concurrent runners of one shape the host can take, and which dimension says so.
///
/// The three per-dimension numbers are shown to the operator rather than just the answer, because
/// "recommended: 3" is not actionable and "disk allows 3" tells them what to buy.
public struct ConcurrencyAdvice: Sendable, Hashable {
  public var cpuAllows: Int
  public var memoryAllows: Int
  public var diskAllows: Int
  /// `min` of the three, floored at 1: a host that fits none is still offered one profile, with
  /// `fitsNone` set so the wizard can say so out loud.
  public var recommended: Int
  public var limitingFactor: LimitingFactor
  public var fitsNone: Bool

  public var summary: String {
    "CPU allows \(cpuAllows) / memory allows \(memoryAllows) / disk allows \(diskAllows)"
      + " -> recommended \(recommended)"
  }
}

/// The concurrency recommendation, computed with the same arithmetic admission uses at runtime
/// (`Scheduler.CapacityCalculator`) rather than a second, divergent estimate.
public enum SetupSizing {
  static let profileId = RunnerProfileID(rawValue: "setup-probe")
  /// Stands in for "this dimension is not the constraint" when a single factor is isolated.
  static let unbounded = UInt64.max / 4

  public static func resources(from facts: SetupHostFacts) -> HostResources {
    HostResources(
      logicalCPUs: facts.cpuCount,
      physicalMemoryBytes: facts.memoryBytes,
      freeDiskBytes: facts.freeDiskBytes)
  }

  /// Capacity for one profile shape, overall and per dimension.
  ///
  /// The per-dimension figures come from re-running the same probe against a budget with the other
  /// two dimensions lifted, so each number means "if only this resource mattered" — honest, and
  /// derived from the real calculator rather than divided by hand.
  public static func advice(
    facts: SetupHostFacts,
    reserve: HostConfig.Reserve = SetupDefaults.reserve,
    resources spec: ResourceSpec = SetupDefaults.linuxResources,
    guestOS: GuestOS = .linux
  ) -> ConcurrencyAdvice {
    let host = HostConfig(reserve: reserve, maxVMs: .auto)
    let full = HostBudget(config: host, resources: resources(from: facts))
    let profile = probeProfile(spec: spec, guestOS: guestOS)

    let overall = capacity(profile, budget: full)
    let cpu = capacity(profile, budget: isolating(.cpu, in: full))
    let memory = capacity(profile, budget: isolating(.memory, in: full))
    let disk = capacity(profile, budget: isolating(.disk, in: full))

    return ConcurrencyAdvice(
      cpuAllows: cpu.cap,
      memoryAllows: memory.cap,
      diskAllows: disk.cap,
      recommended: max(1, overall.cap),
      limitingFactor: overall.limitingFactor,
      fitsNone: overall.cap < 1)
  }

  // MARK: - Internals

  private enum Dimension { case cpu, memory, disk }

  /// The same budget with the other two dimensions lifted out of the way.
  private static func isolating(_ dimension: Dimension, in budget: HostBudget) -> HostBudget {
    HostBudget(
      cpuBudget: dimension == .cpu ? budget.cpuBudget : Double(unbounded),
      memoryBudgetBytes: dimension == .memory ? budget.memoryBudgetBytes : unbounded,
      freeDiskBytes: dimension == .disk ? budget.freeDiskBytes : unbounded,
      diskFloorBytes: dimension == .disk ? budget.diskFloorBytes : 0,
      maxVMs: nil,
      diskOvercommit: budget.diskOvercommit)
  }

  private static func capacity(
    _ profile: RunnerProfileConfig, budget: HostBudget
  ) -> ProfileCapacity {
    CapacityCalculator.profileCapacity(
      profileId: profileId, profile: profile, reservations: [], budget: budget, hostMode: .normal)
  }

  /// A throwaway profile carrying only the fields capacity math reads.
  private static func probeProfile(spec: ResourceSpec, guestOS: GuestOS) -> RunnerProfileConfig {
    RunnerProfileConfig(
      name: profileId.rawValue, scope: "setup", image: "setup-probe", guestOS: guestOS,
      resources: spec)
  }
}
