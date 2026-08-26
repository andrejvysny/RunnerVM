import Foundation
import RunnerCore
@testable import Scheduler
import Testing

@Suite struct DesiredCapacityTests {
  private func capacity(_ cap: Int, current: Int) -> ProfileCapacity {
    ProfileCapacity(cap: cap, limitingFactor: .cpu, currentInstances: current)
  }

  @Test func assignedJobsDriveStarts() {
    let reservations = [
      Fixture.reservation(id: "running", state: .busy, bound: true, ageSeconds: 0),
      Fixture.reservation(id: "starting", state: .startingVM, ageSeconds: 60),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 3, reservations: reservations,
      capacity: capacity(2, current: 2)
    )
    #expect(plan.busyTarget == 3)
    #expect(plan.idleTarget == 0)
    #expect(plan.toStart == 1)
    #expect(plan.toCancel.isEmpty)
  }

  @Test func noDemandAndNoWarmPoolWantsNothing() {
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 0, reservations: [],
      capacity: capacity(4, current: 0)
    )
    #expect(plan == DesiredPlan(busyTarget: 0, idleTarget: 0, toStart: 0, toCancel: []))
  }

  @Test func busyDemandBeatsTheIdleFloor() {
    let profile = Fixture.profile(
      name: "macos", guestOS: .macos, cpu: 6, memoryGiB: 12, diskGiB: 120, minIdle: 2, maxIdle: 2
    )
    let reservations = Fixture.reservations(
      of: profile, profileId: "macos", states: [.busy, .busy], bound: true
    )
    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: 2, reservations: reservations,
      capacity: capacity(0, current: 2)
    )
    #expect(plan.busyTarget == 2)
    #expect(plan.idleTarget == 0)
    #expect(plan.toStart == 0)
    #expect(plan.toCancel.isEmpty)
  }

  @Test func idleFloorFillsWhatBusyDemandLeaves() {
    let profile = Fixture.profile(minIdle: 3, maxIdle: 3)
    let reservations = [Fixture.reservation(id: "busy", state: .busy, bound: true)]
    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: 1, reservations: reservations,
      capacity: capacity(3, current: 1)
    )
    #expect(plan.busyTarget == 1)
    #expect(plan.idleTarget == 3)
    #expect(plan.toStart == 3)
  }

  @Test func demandAboveCapacityIsClamped() {
    let reservations = [Fixture.reservation(id: "busy", state: .busy, bound: true)]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 10, reservations: reservations,
      capacity: capacity(1, current: 1)
    )
    #expect(plan.busyTarget == 2)
    #expect(plan.toStart == 1)
  }

  @Test func negativeDemandIsTreatedAsZero() {
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: -5, reservations: [],
      capacity: capacity(2, current: 0)
    )
    #expect(plan.busyTarget == 0)
    #expect(plan.toStart == 0)
  }

  @Test func overCapacityCancelsNewestUnboundPreBootFirst() {
    let reservations = [
      Fixture.reservation(id: "busy", state: .busy, bound: true, ageSeconds: 0),
      Fixture.reservation(id: "old", state: .cloning, ageSeconds: 60),
      Fixture.reservation(id: "mid", state: .planned, ageSeconds: 120),
      Fixture.reservation(id: "new", state: .startingVM, ageSeconds: 180),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 1, reservations: reservations,
      capacity: capacity(0, current: 4)
    )
    #expect(plan.toStart == 0)
    #expect(plan.toCancel.map(\.rawValue) == ["new", "mid", "old"])
  }

  @Test func onlyTheSurplusIsCancelled() {
    let reservations = [
      Fixture.reservation(id: "a", state: .planned, ageSeconds: 0),
      Fixture.reservation(id: "b", state: .planned, ageSeconds: 60),
      Fixture.reservation(id: "c", state: .planned, ageSeconds: 120),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 2, reservations: reservations,
      capacity: capacity(0, current: 3)
    )
    #expect(plan.toCancel.map(\.rawValue) == ["c"])
  }

  @Test func boundReservationsAreNeverCancelled() {
    let reservations = [
      Fixture.reservation(id: "bound-preboot", state: .waitingForAgent, bound: true, ageSeconds: 0),
      Fixture.reservation(id: "bound-online", state: .runnerOnline, bound: true, ageSeconds: 60),
      Fixture.reservation(id: "bound-busy", state: .busy, bound: true, ageSeconds: 120),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 0, reservations: reservations,
      capacity: capacity(0, current: 3)
    )
    #expect(plan.toCancel.isEmpty)
  }

  @Test func idleBeyondMaxIdleIsTrimmedOldestFirst() {
    let profile = Fixture.profile(minIdle: 1, maxIdle: 1)
    let reservations = [
      Fixture.reservation(id: "idle-old", state: .idle, ageSeconds: 0),
      Fixture.reservation(id: "idle-mid", state: .idle, ageSeconds: 60),
      Fixture.reservation(id: "idle-new", state: .idle, ageSeconds: 120),
    ]
    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: 0, reservations: reservations,
      capacity: capacity(0, current: 3)
    )
    // Surplus is 2 (idleTarget 1); the maxIdle floor keeps exactly one idle VM alive.
    #expect(plan.idleTarget == 1)
    #expect(plan.toCancel.map(\.rawValue) == ["idle-old", "idle-mid"])
  }

  @Test func preBootIsGivenUpBeforeIdle() {
    let reservations = [
      Fixture.reservation(id: "idle-old", state: .idle, ageSeconds: 0),
      Fixture.reservation(id: "idle-new", state: .idle, ageSeconds: 60),
      Fixture.reservation(id: "boot-old", state: .cloning, ageSeconds: 120),
      Fixture.reservation(id: "boot-new", state: .preparing, ageSeconds: 180),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 0, reservations: reservations,
      capacity: capacity(0, current: 4)
    )
    #expect(plan.toCancel.map(\.rawValue) == ["boot-new", "boot-old", "idle-old", "idle-new"])
  }

  @Test func equalTimestampsBreakTiesOnInstanceID() {
    let reservations = [
      Fixture.reservation(id: "zzz", state: .planned, ageSeconds: 0),
      Fixture.reservation(id: "aaa", state: .planned, ageSeconds: 0),
    ]
    let plan = DesiredCapacity.compute(
      profile: Fixture.profile(), assignedJobs: 1, reservations: reservations,
      capacity: capacity(0, current: 2)
    )
    #expect(plan.toCancel.map(\.rawValue) == ["aaa"])
  }

  @Test func capacityAndDesiredStateAgreeOnARealHost() {
    let profile = Fixture.profile(minIdle: 1, maxIdle: 2)
    let profileId = RunnerProfileID(rawValue: "linux-small")
    let reservations = Fixture.reservations(
      of: profile, profileId: "linux-small", states: [.busy]
    )
    let budget = Fixture.budget()
    let capacity = CapacityCalculator.profileCapacity(
      profileId: profileId, profile: profile, reservations: reservations, budget: budget,
      hostMode: .normal
    )
    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: 5, reservations: reservations, capacity: capacity
    )
    // 8 vCPU budget, 4 per instance: one busy already, one more fits.
    #expect(capacity.cap == 1)
    #expect(plan.busyTarget == 2)
    #expect(plan.idleTarget == 0)
    #expect(plan.toStart == 1)
  }
}
