import Foundation
import RunnerCore
@testable import Scheduler
import Testing

/// Randomised but reproducible host/profile/reservation states. Every reservation is admitted
/// through `fits`, so the starting point is always a state the scheduler could have produced.
struct Scenario {
  var budget: HostBudget
  var profiles: [(id: RunnerProfileID, config: RunnerProfileConfig)]
  var reservations: [Reservation]
  var assignedJobs: [RunnerProfileID: Int]
  var throttle: Int
  var lastServed: RunnerProfileID?

  static let liveStates: [InstanceState] = [
    .planned, .preparing, .cloning, .startingWorker, .startingVM, .waitingForAgent, .idle,
    .configuringRunner, .runnerOnline, .busy, .cleaning, .stopping,
  ]

  static func make(seed: UInt64) -> Scenario {
    var rng = SplitMix64(seed: seed)
    let budget = HostBudget(
      config: Fixture.hostConfig(
        cpuReserve: rng.int(0 ... 4),
        memoryReserveGiB: UInt64(rng.int(0 ... 8)),
        diskReserveGiB: UInt64(rng.int(0 ... 100)),
        cpuOvercommit: rng.pick([1.0, 1.5, 2.0]),
        memoryOvercommit: rng.pick([1.0, 1.25]),
        maxVMs: rng.bool() ? .auto : .count(rng.int(1 ... 8))
      ),
      resources: HostResources(
        logicalCPUs: rng.int(4 ... 32),
        physicalMemoryBytes: UInt64(rng.int(8 ... 128)) * Fixture.gib,
        freeDiskBytes: UInt64(rng.int(200 ... 2000)) * Fixture.gib
      )
    )
    let profiles = (0 ..< rng.int(1 ... 4)).map { index in makeProfile(index: index, rng: &rng) }
    let reservations = makeReservations(profiles: profiles, budget: budget, rng: &rng)
    var assigned: [RunnerProfileID: Int] = [:]
    // Half the profiles get zero demand so cancellation paths are exercised, not just starts.
    for profile in profiles {
      assigned[profile.id] = rng.bool() ? 0 : rng.int(1 ... 6)
    }
    return Scenario(
      budget: budget,
      profiles: profiles,
      reservations: reservations,
      assignedJobs: assigned,
      throttle: StartupThrottle.allowedStarts(
        pending: rng.int(0 ... 10), inFlightStarts: rng.int(0 ... 1), limit: rng.int(1 ... 4)
      ),
      lastServed: rng.bool() ? profiles[rng.int(0 ... (profiles.count - 1))].id : nil
    )
  }

  private static func makeProfile(index: Int, rng: inout SplitMix64)
    -> (id: RunnerProfileID, config: RunnerProfileConfig)
  {
    let minIdle = rng.int(0 ... 2)
    let config = Fixture.profile(
      name: "p\(index)",
      guestOS: rng.bool() ? .macos : .linux,
      cpu: rng.int(1 ... 4),
      memoryGiB: UInt64(rng.int(1 ... 8)),
      diskGiB: UInt64(rng.int(10 ... 100)),
      minIdle: minIdle,
      maxIdle: minIdle + rng.int(0 ... 2),
      maxInstances: rng.bool() ? nil : rng.int(0 ... 5)
    )
    return (RunnerProfileID(rawValue: "p\(index)"), config)
  }

  private static func makeReservations(
    profiles: [(id: RunnerProfileID, config: RunnerProfileConfig)],
    budget: HostBudget,
    rng: inout SplitMix64
  ) -> [Reservation] {
    var reservations: [Reservation] = []
    for index in 0 ..< rng.int(0 ... 8) {
      let profile = profiles[rng.int(0 ... (profiles.count - 1))]
      let request = ResourceRequest(profile: profile.config)
      guard CapacityCalculator.fits(
        request: request, reservations: reservations, budget: budget
      ).isFit else { continue }
      let state = liveStates[rng.int(0 ... (liveStates.count - 1))]
      reservations.append(
        Fixture.reservation(
          id: "r\(index)",
          profile: profile.id.rawValue,
          guestOS: profile.config.guestOS,
          cpu: profile.config.resources.cpuCount,
          memoryGiB: profile.config.resources.memoryBytes / Fixture.gib,
          diskGiB: profile.config.resources.diskBytes / Fixture.gib,
          state: state,
          bound: rng.bool(),
          ageSeconds: TimeInterval(index) * 60
        )
      )
    }
    return reservations
  }

  func plans(hostMode: HostMode = .normal) -> [(ProfileStartPlan, ProfileCapacity)] {
    profiles.map { profile in
      let mine = reservations.filter { $0.profileId == profile.id }
      let capacity = CapacityCalculator.profileCapacity(
        profileId: profile.id, profile: profile.config, reservations: reservations,
        budget: budget, hostMode: hostMode
      )
      let plan = DesiredCapacity.compute(
        profile: profile.config, assignedJobs: assignedJobs[profile.id] ?? 0,
        reservations: mine, capacity: capacity
      )
      let start = ProfileStartPlan(
        profileId: profile.id, plan: plan, request: ResourceRequest(profile: profile.config)
      )
      return (start, capacity)
    }
  }

  /// The reservation set that would exist after acting on an allocation.
  func applied(_ result: AllocationResult) -> [Reservation] {
    var applied = reservations
    for decision in result.decisions {
      guard let profile = profiles.first(where: { $0.id == decision.profileId }) else { continue }
      let request = ResourceRequest(profile: profile.config)
      for index in 0 ..< decision.count {
        applied.append(.simulated(request: request, profileId: decision.profileId, sequence: index))
      }
    }
    return applied
  }
}

private let seeds: [UInt64] = (1 ... 64).map { UInt64($0) &* 0x9E37_79B9 }

@Suite struct SchedulerPropertyTests {
  @Test(arguments: seeds)
  func desiredStateNeverExceedsCapacity(seed: UInt64) throws {
    let scenario = Scenario.make(seed: seed)
    for (start, capacity) in scenario.plans() {
      let profile = try #require(scenario.profiles.first { $0.id == start.profileId }?.config)
      let mine = scenario.reservations.filter { $0.profileId == start.profileId }
      #expect(start.plan.toStart <= capacity.cap)
      #expect(start.plan.busyTarget <= max(0, scenario.assignedJobs[start.profileId] ?? 0))
      #expect(start.plan.idleTarget <= profile.warmPool.minIdle)
      #expect(start.plan.desiredTotal <= mine.count + capacity.cap)
      #expect(start.plan.toCancel.count <= mine.count)
    }
  }

  @Test(arguments: seeds)
  func cancellationOnlyEverTargetsUnboundInstances(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    for (start, _) in scenario.plans() {
      let mine = scenario.reservations.filter { $0.profileId == start.profileId }
      let cancelled = start.plan.toCancel
      #expect(Set(cancelled).count == cancelled.count)
      for id in cancelled {
        let reservation = mine.first { $0.instanceId == id }
        #expect(reservation != nil)
        #expect(reservation?.bound == false)
        #expect(reservation.map { $0.isCancellablePreBoot || $0.isCancellableIdle } == true)
      }
      // Cancelling and starting in the same pass would fight each other.
      #expect(start.plan.toStart == 0 || cancelled.isEmpty)
    }
  }

  @Test(arguments: seeds)
  func allocationStaysInsideEveryBudgetDimension(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    let result = Allocator.allocate(
      plans: scenario.plans().map(\.0), reservations: scenario.reservations,
      budget: scenario.budget, throttle: scenario.throttle, lastServed: scenario.lastServed
    )
    let totals = CapacityCalculator.Totals(scenario.applied(result))
    #expect(Double(totals.cpu) <= scenario.budget.cpuBudget + CapacityCalculator.cpuEpsilon)
    #expect(totals.memory <= scenario.budget.memoryBudgetBytes)
    #expect(totals.disk <= scenario.budget.diskBudgetBytes)
    #expect(totals.macOS <= HostConstants.macOSGuestLimit)
    if let maxVMs = scenario.budget.maxVMs { #expect(totals.count <= maxVMs) }
  }

  @Test(arguments: seeds)
  func allocationHonoursThrottleAndPerProfileDemand(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    let plans = scenario.plans().map(\.0)
    let result = Allocator.allocate(
      plans: plans, reservations: scenario.reservations, budget: scenario.budget,
      throttle: scenario.throttle, lastServed: scenario.lastServed
    )
    #expect(result.totalStarts <= scenario.throttle)
    for decision in result.decisions {
      let wanted = plans.first { $0.profileId == decision.profileId }?.plan.toStart ?? 0
      #expect(decision.count <= wanted)
      #expect(decision.count > 0)
    }
    if result.totalStarts == 0 { #expect(result.lastServed == scenario.lastServed) }
  }

  @Test(arguments: seeds)
  func equalInputsProduceEqualDecisions(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    let plans = scenario.plans().map(\.0)
    let first = Allocator.allocate(
      plans: plans, reservations: scenario.reservations, budget: scenario.budget,
      throttle: scenario.throttle, lastServed: scenario.lastServed
    )
    let second = Allocator.allocate(
      plans: plans, reservations: scenario.reservations, budget: scenario.budget,
      throttle: scenario.throttle, lastServed: scenario.lastServed
    )
    #expect(first == second)
    #expect(Scenario.make(seed: seed).plans().map(\.0) == plans)
  }

  @Test(arguments: seeds)
  func drainingHostsNeverStartAnything(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    let plans = scenario.plans(hostMode: .draining).map(\.0)
    let result = Allocator.allocate(
      plans: plans, reservations: scenario.reservations, budget: scenario.budget,
      throttle: scenario.throttle, lastServed: scenario.lastServed
    )
    #expect(result.totalStarts == 0)
    for profile in scenario.profiles {
      #expect(CapacityCalculator.advertisedCapacity(
        profileId: profile.id, profile: profile.config, reservations: scenario.reservations,
        budget: scenario.budget, hostMode: .draining
      ) == 0)
    }
  }

  @Test(arguments: seeds)
  func profileCapacityIsExactlyWhatAdmissionWouldAccept(seed: UInt64) {
    let scenario = Scenario.make(seed: seed)
    for profile in scenario.profiles {
      let capacity = CapacityCalculator.profileCapacity(
        profileId: profile.id, profile: profile.config, reservations: scenario.reservations,
        budget: scenario.budget, hostMode: .normal
      )
      guard capacity.cap < CapacityCalculator.degenerateProbeCeiling else { continue }
      let request = ResourceRequest(profile: profile.config)
      var simulated = scenario.reservations
      for index in 0 ..< capacity.cap {
        #expect(CapacityCalculator.fits(
          request: request, reservations: simulated, budget: scenario.budget
        ).isFit)
        simulated.append(.simulated(request: request, profileId: profile.id, sequence: index))
      }
      let headroomExhausted = capacity.limitingFactor == .profileMaxInstances
      let nextFits = CapacityCalculator.fits(
        request: request, reservations: simulated, budget: scenario.budget
      ).isFit
      #expect(headroomExhausted || !nextFits)
    }
  }

  @Test func roundRobinStarvesNobodyOverSuccessivePasses() throws {
    let profiles = [
      (RunnerProfileID(rawValue: "a"), Fixture.profile(name: "a", cpu: 1, memoryGiB: 1, diskGiB: 1)),
      (RunnerProfileID(rawValue: "b"), Fixture.profile(name: "b", cpu: 1, memoryGiB: 1, diskGiB: 1)),
      (RunnerProfileID(rawValue: "c"), Fixture.profile(name: "c", cpu: 1, memoryGiB: 1, diskGiB: 1)),
    ]
    let budget = Fixture.budget()
    var reservations: [Reservation] = []
    var lastServed: RunnerProfileID?
    var starts: [RunnerProfileID: Int] = [:]
    // One start per pass: only the rotation can keep every profile moving.
    for pass in 0 ..< profiles.count {
      let plans = profiles.map { id, config in
        ProfileStartPlan(
          profileId: id,
          plan: DesiredPlan(busyTarget: 5, idleTarget: 0, toStart: 5, toCancel: []),
          request: ResourceRequest(profile: config)
        )
      }
      let result = Allocator.allocate(
        plans: plans, reservations: reservations, budget: budget, throttle: 1,
        lastServed: lastServed
      )
      #expect(result.totalStarts == 1)
      lastServed = result.lastServed
      for decision in result.decisions {
        starts[decision.profileId, default: 0] += decision.count
        let config = try #require(profiles.first { $0.0 == decision.profileId }?.1)
        reservations.append(
          .simulated(
            request: ResourceRequest(profile: config), profileId: decision.profileId,
            sequence: pass
          )
        )
      }
    }
    for (id, _) in profiles {
      #expect(starts[id, default: 0] >= 1)
    }
  }
}
