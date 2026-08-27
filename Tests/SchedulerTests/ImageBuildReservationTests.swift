import Foundation
import RunnerCore
import Testing

@testable import Scheduler

/// An image build costs the host cpu, memory and disk exactly like an instance does, but it is not
/// an instance: nothing may cancel it, and no profile may count it as one of its own.
@Suite struct ImageBuildReservationTests {
  static func build(
    cpu: Int = 4, memoryGiB: UInt64 = 8, diskGiB: UInt64 = 80, guestOS: GuestOS = .linux
  ) -> Reservation {
    Reservation.imageBuild(
      id: "build-1", cpuCount: cpu, memoryBytes: memoryGiB * Fixture.gib,
      diskBytes: diskGiB * Fixture.gib, createdAt: Fixture.epoch, guestOS: guestOS)
  }

  @Test func theSentinelProfileCannotCollideWithAConfiguredProfile() {
    // `@` is not a legal character in a configured profile name, which is what makes the sentinel
    // safe to mix into the same reservation list.
    #expect(RunnerProfileID.imageBuild.rawValue == "@image-build")
    #expect(Self.build().profileId == .imageBuild)
    #expect(Self.build().isImageBuild)
    #expect(!Fixture.reservation(id: "i-1").isImageBuild)
  }

  @Test func hostTotalsIncludeTheBuild() {
    let budget = Fixture.budget()
    let profile = Fixture.profile()

    // cpuBudget is 8: the profile's 4 vCPUs fit on an empty host but not beside a 4-vCPU build.
    #expect(CapacityCalculator.fits(
      request: Fixture.request(profile), reservations: [], budget: budget).isFit)
    let rejection = CapacityCalculator.fits(
      request: Fixture.request(profile), reservations: [Self.build(cpu: 8)], budget: budget)
    #expect(rejection.rejections.contains(.cpu(needed: 4, available: 0)))
  }

  @Test func perProfileCapacityIsReducedButTheBuildIsNotCountedAsAnInstance() {
    let budget = Fixture.budget()
    let profile = Fixture.profile()
    let profileId = RunnerProfileID(rawValue: "linux-small")

    let empty = CapacityCalculator.profileCapacity(
      profileId: profileId, profile: profile, reservations: [], budget: budget, hostMode: .normal)
    let charged = CapacityCalculator.profileCapacity(
      profileId: profileId, profile: profile, reservations: [Self.build()], budget: budget,
      hostMode: .normal)

    #expect(empty.cap == 2)
    #expect(charged.cap == 1)
    // The build consumes budget but is not one of this profile's instances, so `total` — what
    // `X-ScaleSetMaxCapacity` reports — drops with it instead of being inflated by it.
    #expect(charged.currentInstances == 0)
    #expect(charged.total == 1)
  }

  @Test func aMacOSBuildCountsAgainstTheGuestLimit() {
    let budget = Fixture.budget()
    let macProfile = Fixture.profile(name: "mac", guestOS: .macos, cpu: 1, memoryGiB: 1, diskGiB: 1)
    let builds = (0..<HostConstants.macOSGuestLimit).map { _ in
      Self.build(cpu: 1, memoryGiB: 1, diskGiB: 1, guestOS: .macos)
    }

    let result = CapacityCalculator.fits(
      request: Fixture.request(macProfile), reservations: builds, budget: budget)

    #expect(result.rejections.contains(.macOSGuestLimit(limit: HostConstants.macOSGuestLimit)))
  }

  // MARK: - Cancellation

  @Test func cancellationNeverSelectsABuild() {
    let build = Self.build()
    #expect(!build.isCancellablePreBoot)
    #expect(!build.isCancellableIdle)

    let idle = Fixture.reservations(
      of: Fixture.profile(), profileId: "linux-small", states: [.idle, .planned])
    let victims = DesiredCapacity.cancellations(
      surplus: 3, reservations: idle + [build],
      profile: Fixture.profile(maxIdle: 0))

    #expect(!victims.contains(build.instanceId))
    #expect(victims.count == 2)
  }

  /// `DesiredCapacity.compute` is fed one profile's reservations, which by construction never
  /// include the sentinel; this pins the arithmetic that follows from that.
  @Test func desiredCapacityPlansAgainstTheReducedCapOnly() {
    let profile = Fixture.profile(minIdle: 2)
    let capacity = CapacityCalculator.profileCapacity(
      profileId: RunnerProfileID(rawValue: "linux-small"), profile: profile,
      reservations: [Self.build()], budget: Fixture.budget(), hostMode: .normal)

    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: 4, reservations: [], capacity: capacity)

    #expect(plan.busyTarget == 1)
    #expect(plan.idleTarget == 0)
    #expect(plan.toStart == 1)
    #expect(plan.toCancel.isEmpty)
  }
}
