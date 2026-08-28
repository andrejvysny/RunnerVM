import Foundation
import RunnerCore
@testable import Scheduler
import Testing

private let maxVMsCases: [(HostConfig.MaxVMs, Int?)] = [(.auto, nil), (.count(3), 3), (.count(-1), 0)]

@Suite struct HostBudgetTests {
  @Test func defaultsSubtractReserveAndKeepMemoryExact() {
    let budget = Fixture.budget()
    #expect(budget.cpuBudget == 8)
    #expect(budget.memoryBudgetBytes == 26 * Fixture.gib)
    #expect(budget.diskBudgetBytes == 950 * Fixture.gib)
    #expect(budget.maxVMs == nil)
  }

  @Test func cpuOvercommitRaisesTheCPUBudget() {
    let budget = Fixture.budget(config: Fixture.hostConfig(cpuOvercommit: 1.5))
    #expect(budget.cpuBudget == 12)
  }

  @Test func memoryOvercommitScalesButDefaultsToOne() {
    let overcommitted = Fixture.budget(config: Fixture.hostConfig(memoryOvercommit: 1.5))
    #expect(overcommitted.memoryBudgetBytes == 39 * Fixture.gib)
    #expect(Fixture.budget().memoryBudgetBytes == 26 * Fixture.gib)
  }

  /// Admission reserves each guest's *apparent* disk size, but an instance disk is an APFS clone
  /// of the image that only grows as the job writes. `host.overcommit.disk` is the opt-in that
  /// says so — without it a 50 GB-nominal / 30 GiB-actual macOS image cannot be admitted on a host
  /// that would run it comfortably.
  @Test func diskOvercommitScalesButDefaultsToOne() {
    #expect(Fixture.budget().diskBudgetBytes == 950 * Fixture.gib)
    let overcommitted = Fixture.budget(config: Fixture.hostConfig(diskOvercommit: 1.4))
    #expect(overcommitted.diskBudgetBytes == 1330 * Fixture.gib)
  }

  /// The reserve is the space macOS and the daemon's own logs need; overcommitting into it would
  /// defeat the point of having a floor, so the ratio applies strictly after the subtraction.
  @Test func diskOvercommitAppliesAfterTheFloorNotBefore() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(diskReserveGiB: 50, diskOvercommit: 2.0),
      resources: Fixture.resources(cpus: 10, memoryGiB: 32, freeDiskGiB: 100)
    )
    #expect(budget.diskBudgetBytes == 100 * Fixture.gib)   // (100 - 50) * 2, not (100 * 2) - 50
  }

  @Test func reserveLargerThanPhysicalYieldsZero() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(cpuReserve: 32, memoryReserveGiB: 64, diskReserveGiB: 4000),
      resources: Fixture.resources(cpus: 10, memoryGiB: 32, freeDiskGiB: 100)
    )
    #expect(budget.cpuBudget == 0)
    #expect(budget.memoryBudgetBytes == 0)
    #expect(budget.diskBudgetBytes == 0)
  }

  @Test func zeroOvercommitIsNotNegativeCapacity() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(cpuOvercommit: -1, memoryOvercommit: 0, diskOvercommit: -1)
    )
    #expect(budget.cpuBudget == 0)
    #expect(budget.memoryBudgetBytes == 0)
    #expect(budget.diskBudgetBytes == 0)
  }

  @Test(arguments: maxVMsCases)
  func maxVMsResolution(maxVMs: HostConfig.MaxVMs, expected: Int?) {
    #expect(Fixture.budget(config: Fixture.hostConfig(maxVMs: maxVMs)).maxVMs == expected)
  }

  @Test func saturatingHelpersNeverTrap() {
    #expect(SaturatingMath.sub(1, 5) == 0)
    #expect(SaturatingMath.add(.max, 10) == .max)
    #expect(SaturatingMath.scale(.max, by: 2) == .max)
    #expect(SaturatingMath.scale(100, by: .nan) == 0)
    // A non-finite ratio is a broken config: report no capacity rather than infinite capacity.
    #expect(SaturatingMath.scale(100, by: .infinity) == 0)
  }
}
