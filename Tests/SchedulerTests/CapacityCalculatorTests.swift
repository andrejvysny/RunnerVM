import Foundation
import RunnerCore
@testable import Scheduler
import Testing

@Suite struct FitTests {
  private let profile = Fixture.profile()

  @Test func emptyHostFitsTheProfile() {
    #expect(CapacityCalculator.fits(
      request: Fixture.request(profile), reservations: [], budget: Fixture.budget()
    ) == .fits)
  }

  @Test func cpuExhaustionIsReported() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(cpuReserve: 2),
      resources: Fixture.resources(cpus: 10)
    )
    let taken = [Fixture.reservation(id: "a", cpu: 6, memoryGiB: 1, diskGiB: 1)]
    let request = ResourceRequest(
      guestOS: .linux,
      cpuCount: 4,
      memoryBytes: Fixture.gib,
      diskReservationBytes: Fixture.gib
    )
    #expect(CapacityCalculator.fits(request: request, reservations: taken, budget: budget)
      == .rejected([.cpu(needed: 4, available: 2)]))
  }

  @Test func memoryExhaustionIsReported() {
    let budget = Fixture.budget()
    let taken = (0 ..< 3).map {
      Fixture.reservation(id: "m\($0)", cpu: 0, memoryGiB: 8, diskGiB: 0)
    }
    let request = ResourceRequest(
      guestOS: .linux, cpuCount: 0, memoryBytes: 8 * Fixture.gib, diskReservationBytes: 0
    )
    #expect(CapacityCalculator.fits(request: request, reservations: taken, budget: budget)
      == .rejected([.memory(needed: 8 * Fixture.gib, available: 2 * Fixture.gib)]))
  }

  @Test func diskCheckSubtractsFloorAndExistingReservations() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(diskReserveGiB: 50),
      resources: Fixture.resources(freeDiskGiB: 200)
    )
    let taken = [Fixture.reservation(id: "a", cpu: 0, memoryGiB: 0, diskGiB: 100)]
    let fitting = ResourceRequest(
      guestOS: .linux, cpuCount: 0, memoryBytes: 0, diskReservationBytes: 50 * Fixture.gib
    )
    let tooBig = ResourceRequest(
      guestOS: .linux, cpuCount: 0, memoryBytes: 0, diskReservationBytes: 51 * Fixture.gib
    )
    #expect(CapacityCalculator.fits(request: fitting, reservations: taken, budget: budget) == .fits)
    #expect(CapacityCalculator.fits(request: tooBig, reservations: taken, budget: budget)
      == .rejected([.disk(needed: 51 * Fixture.gib, available: 50 * Fixture.gib)]))
  }

  @Test func maxVMsCeilingIsIndependentOfResources() {
    let budget = Fixture.budget(config: Fixture.hostConfig(maxVMs: .count(2)))
    let taken = [
      Fixture.reservation(id: "a", cpu: 0, memoryGiB: 0, diskGiB: 0),
      Fixture.reservation(id: "b", cpu: 0, memoryGiB: 0, diskGiB: 0),
    ]
    let request = ResourceRequest(
      guestOS: .linux, cpuCount: 1, memoryBytes: Fixture.gib, diskReservationBytes: Fixture.gib
    )
    #expect(CapacityCalculator.fits(request: request, reservations: taken, budget: budget)
      == .rejected([.maxVMs(limit: 2)]))
  }

  @Test func thirdMacOSGuestIsRejectedEvenWithFreeMemory() {
    let budget = Fixture.budget(resources: Fixture.resources(cpus: 40, memoryGiB: 256))
    let macProfile = Fixture.profile(name: "macos", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120)
    let taken = Fixture.reservations(of: macProfile, profileId: "macos", states: [.busy, .idle])
    #expect(CapacityCalculator.fits(
      request: Fixture.request(macProfile), reservations: taken, budget: budget
    ) == .rejected([.macOSGuestLimit(limit: HostConstants.macOSGuestLimit)]))
  }

  @Test func linuxIsUnaffectedByTheMacOSCap() {
    let budget = Fixture.budget(resources: Fixture.resources(cpus: 40, memoryGiB: 256))
    let macProfile = Fixture.profile(name: "macos", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120)
    let taken = Fixture.reservations(of: macProfile, profileId: "macos", states: [.busy, .idle])
    #expect(CapacityCalculator.fits(
      request: Fixture.request(profile), reservations: taken, budget: budget
    ) == .fits)
  }

  @Test func allFailingDimensionsAreReportedInAFixedOrder() {
    let budget = Fixture.budget(
      config: Fixture.hostConfig(maxVMs: .count(1)),
      resources: Fixture.resources(cpus: 4, memoryGiB: 8, freeDiskGiB: 51)
    )
    let taken = [
      Fixture.reservation(id: "m", guestOS: .macos, cpu: 2, memoryGiB: 2, diskGiB: 1),
      Fixture.reservation(id: "n", guestOS: .macos, cpu: 0, memoryGiB: 0, diskGiB: 0),
    ]
    let request = ResourceRequest(
      guestOS: .macos, cpuCount: 8, memoryBytes: 64 * Fixture.gib,
      diskReservationBytes: 64 * Fixture.gib
    )
    let reasons = CapacityCalculator.fits(request: request, reservations: taken, budget: budget)
      .rejections
    #expect(reasons.count == 5)
    #expect(LimitingFactor(reasons.first) == .cpu)
    #expect(reasons.last == .macOSGuestLimit(limit: 2))
  }

  @Test func cpuBudgetBoundaryIsNotLostToFloatingPointError() {
    // 45 usable cpus × 1.4 is 62.99999999999999 in binary floating point, not 63.
    let budget = Fixture.budget(
      config: Fixture.hostConfig(cpuReserve: 1, cpuOvercommit: 1.4),
      resources: Fixture.resources(cpus: 46, memoryGiB: 256)
    )
    #expect(budget.cpuBudget < 63)
    let request = ResourceRequest(
      guestOS: .linux, cpuCount: 63, memoryBytes: 0, diskReservationBytes: 0
    )
    #expect(CapacityCalculator.fits(request: request, reservations: [], budget: budget) == .fits)
  }
}

@Suite struct ProfileCapacityTests {
  private let linux = RunnerProfileID(rawValue: "linux-small")

  @Test func capacityIsBoundedByTheTightestDimension() {
    let profile = Fixture.profile(memoryGiB: 8)
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: [], budget: Fixture.budget(),
      hostMode: .normal
    )
    // 26 GiB budget / 8 GiB, but only 8 cpu budget / 4 vCPU = 2.
    #expect(capacity.cap == 2)
    #expect(capacity.limitingFactor == .cpu)
    #expect(capacity.currentInstances == 0)
  }

  @Test func capacityRespectsProfileMaxInstances() {
    let profile = Fixture.profile(cpu: 1, memoryGiB: 1, diskGiB: 1, maxInstances: 3)
    let existing = Fixture.reservations(of: profile, profileId: "linux-small", states: [.idle])
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: existing, budget: Fixture.budget(),
      hostMode: .normal
    )
    #expect(capacity.cap == 2)
    #expect(capacity.limitingFactor == .profileMaxInstances)
    #expect(capacity.currentInstances == 1)
    #expect(capacity.total == 3)
  }

  @Test func profileAtItsLimitHasNoCapacity() {
    let profile = Fixture.profile(cpu: 1, memoryGiB: 1, diskGiB: 1, maxInstances: 1)
    let existing = Fixture.reservations(of: profile, profileId: "linux-small", states: [.busy])
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: existing, budget: Fixture.budget(),
      hostMode: .normal
    )
    #expect(capacity.cap == 0)
    #expect(capacity.limitingFactor == .profileMaxInstances)
  }

  @Test func macOSCapacityNeverExceedsTwoSlots() {
    let profile = Fixture.profile(name: "macos", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120)
    let capacity = CapacityCalculator.profileCapacity(
      profileId: RunnerProfileID(rawValue: "macos"), profile: profile, reservations: [],
      budget: Fixture.budget(resources: Fixture.resources(cpus: 40, memoryGiB: 256)),
      hostMode: .normal
    )
    #expect(capacity.cap == HostConstants.macOSGuestLimit)
    #expect(capacity.limitingFactor == .macOSGuestLimit)
  }

  @Test(arguments: [HostMode.draining, HostMode.offline])
  func nonAdmittingHostModesHaveNoCapacity(mode: HostMode) {
    let profile = Fixture.profile()
    let existing = Fixture.reservations(of: profile, profileId: "linux-small", states: [.busy])
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: existing, budget: Fixture.budget(),
      hostMode: mode
    )
    #expect(capacity.cap == 0)
    #expect(capacity.limitingFactor == .hostMode)
    #expect(capacity.currentInstances == 1)
  }

  @Test func advertisedCapacityCountsExistingRunnersAndZeroesWhenDraining() {
    let profile = Fixture.profile(cpu: 1, memoryGiB: 1, diskGiB: 1, maxInstances: 4)
    let existing = Fixture.reservations(of: profile, profileId: "linux-small", states: [.busy, .idle])
    let normal = CapacityCalculator.advertisedCapacity(
      profileId: linux, profile: profile, reservations: existing, budget: Fixture.budget(),
      hostMode: .normal
    )
    let draining = CapacityCalculator.advertisedCapacity(
      profileId: linux, profile: profile, reservations: existing, budget: Fixture.budget(),
      hostMode: .draining
    )
    #expect(normal == 4)
    #expect(draining == 0)
  }

  @Test func otherProfilesConsumeHostCapacityButNotTheProfileSlot() {
    let profile = Fixture.profile(cpu: 4, memoryGiB: 8, diskGiB: 80)
    let other = Fixture.reservations(of: profile, profileId: "other", states: [.busy])
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: other, budget: Fixture.budget(),
      hostMode: .normal
    )
    #expect(capacity.currentInstances == 0)
    #expect(capacity.cap == 1)
  }

  @Test func aRequestConsumingNothingStopsAtTheProbeCeiling() {
    let profile = Fixture.profile(cpu: 0, memoryGiB: 0, diskGiB: 0)
    let capacity = CapacityCalculator.profileCapacity(
      profileId: linux, profile: profile, reservations: [], budget: Fixture.budget(),
      hostMode: .normal
    )
    #expect(capacity.cap == CapacityCalculator.degenerateProbeCeiling)
    #expect(capacity.limitingFactor == .none)
  }
}
