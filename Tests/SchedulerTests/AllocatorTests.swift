import Foundation
import RunnerCore
@testable import Scheduler
import Testing

private let a = RunnerProfileID(rawValue: "a")
private let b = RunnerProfileID(rawValue: "b")
private let c = RunnerProfileID(rawValue: "c")

@Suite struct RoundRobinFairnessTests {
  @Test func rotationStartsAfterTheLastServedProfile() {
    #expect(RoundRobinFairness.order(profilesWithDemand: [a, b, c], lastServed: b) == [c, a, b])
    #expect(RoundRobinFairness.order(profilesWithDemand: [a, b, c], lastServed: c) == [a, b, c])
  }

  @Test func unknownOrMissingLastServedKeepsTheOrder() {
    #expect(RoundRobinFairness.order(profilesWithDemand: [a, b, c], lastServed: nil) == [a, b, c])
    #expect(
      RoundRobinFairness.order(
        profilesWithDemand: [a, b], lastServed: RunnerProfileID(rawValue: "gone")
      ) == [a, b]
    )
    #expect(RoundRobinFairness.order(profilesWithDemand: [], lastServed: a) == [])
  }
}

@Suite struct StartupThrottleTests {
  @Test(arguments: throttleCases)
  func allowedStarts(pending: Int, inFlight: Int, limit: Int, expected: Int) {
    #expect(
      StartupThrottle.allowedStarts(pending: pending, inFlightStarts: inFlight, limit: limit)
        == expected
    )
  }
}

private let throttleCases: [(Int, Int, Int, Int)] = [
  (5, 0, 2, 2), (5, 1, 2, 1), (5, 2, 2, 0), (5, 3, 2, 0), (1, 0, 2, 1),
  (0, 0, 2, 0), (5, 0, 0, 0), (-3, 0, 2, 0), (5, -1, 2, 2),
]

@Suite struct AllocatorTests {
  private let small = Fixture.profile(cpu: 1, memoryGiB: 1, diskGiB: 1)
  private let big = Fixture.profile(cpu: 4, memoryGiB: 8, diskGiB: 80)

  private func plan(_ profileId: RunnerProfileID, toStart: Int, profile: RunnerProfileConfig)
    -> ProfileStartPlan
  {
    ProfileStartPlan(
      profileId: profileId,
      plan: DesiredPlan(busyTarget: toStart, idleTarget: 0, toStart: toStart, toCancel: []),
      request: Fixture.request(profile)
    )
  }

  @Test func startsAreHandedOutOneProfileAtATime() {
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 3, profile: small), plan(b, toStart: 3, profile: small)],
      reservations: [], budget: Fixture.budget(), throttle: 3, lastServed: nil
    )
    #expect(result.decisions == [
      StartDecision(profileId: a, count: 2),
      StartDecision(profileId: b, count: 1),
    ])
    #expect(result.lastServed == a)
    #expect(result.totalStarts == 3)
  }

  @Test func theNextPassStartsAfterTheProfileServedLast() {
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 3, profile: small), plan(b, toStart: 3, profile: small)],
      reservations: [], budget: Fixture.budget(), throttle: 3, lastServed: a
    )
    #expect(result.decisions == [
      StartDecision(profileId: b, count: 2),
      StartDecision(profileId: a, count: 1),
    ])
    #expect(result.lastServed == b)
  }

  @Test func allocationStopsAtTheResourceBudget() {
    // 8 vCPU of budget, 4 per instance.
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 4, profile: big), plan(b, toStart: 4, profile: big)],
      reservations: [], budget: Fixture.budget(), throttle: 100, lastServed: nil
    )
    #expect(result.totalStarts == 2)
    #expect(result.decisions == [
      StartDecision(profileId: a, count: 1),
      StartDecision(profileId: b, count: 1),
    ])
  }

  @Test func allocationNeverExceedsTheMacOSGuestLimit() {
    let mac = Fixture.profile(name: "macos", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120)
    let macB = Fixture.profile(name: "macos2", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120)
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 3, profile: mac), plan(b, toStart: 3, profile: macB)],
      reservations: [],
      budget: Fixture.budget(resources: Fixture.resources(cpus: 64, memoryGiB: 512)),
      throttle: 100, lastServed: nil
    )
    #expect(result.totalStarts == HostConstants.macOSGuestLimit)
  }

  @Test func existingReservationsCountAgainstTheBudget() {
    let taken = Fixture.reservations(of: big, profileId: "other", states: [.busy])
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 4, profile: big)],
      reservations: taken, budget: Fixture.budget(), throttle: 100, lastServed: nil
    )
    #expect(result.totalStarts == 1)
  }

  @Test func nothingToStartLeavesTheRotationUntouched() {
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 0, profile: small)],
      reservations: [], budget: Fixture.budget(), throttle: 5, lastServed: c
    )
    #expect(result.decisions.isEmpty)
    #expect(result.lastServed == c)
  }

  @Test func anExhaustedThrottleGrantsNothing() {
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 5, profile: small)],
      reservations: [], budget: Fixture.budget(), throttle: 0, lastServed: nil
    )
    #expect(result.decisions.isEmpty)
    #expect(result.lastServed == nil)
  }

  @Test func aProfileThatCannotFitDoesNotBlockOthers() {
    let result = Allocator.allocate(
      plans: [
        plan(a, toStart: 2, profile: Fixture.profile(cpu: 64, memoryGiB: 1, diskGiB: 1)),
        plan(b, toStart: 2, profile: small),
      ],
      reservations: [], budget: Fixture.budget(), throttle: 4, lastServed: nil
    )
    #expect(result.decisions == [StartDecision(profileId: b, count: 2)])
    #expect(result.lastServed == b)
  }

  @Test func duplicateProfilePlansUseTheFirstEntry() {
    let result = Allocator.allocate(
      plans: [plan(a, toStart: 1, profile: small), plan(a, toStart: 5, profile: small)],
      reservations: [], budget: Fixture.budget(), throttle: 10, lastServed: nil
    )
    #expect(result.decisions == [StartDecision(profileId: a, count: 1)])
  }
}

@Suite struct PlacementTests {
  @Test func singleHostStrategyAlwaysReturnsTheLocalHost() throws {
    let host = HostID(rawValue: "host-1")
    let strategy = SingleHostPlacementStrategy(localHost: host)
    #expect(try strategy.chooseHost(for: Fixture.request(Fixture.profile())) == host)
    #expect(
      try strategy.chooseHost(
        for: ResourceRequest(
          guestOS: .macos, cpuCount: 999, memoryBytes: .max, diskReservationBytes: .max
        )
      ) == host
    )
  }
}
