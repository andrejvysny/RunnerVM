import Foundation
import RunnerCore

/// Round-robin across profiles with pending demand (spec §106). FIFO inside a profile is the
/// caller's ordering of its own queue.
public enum RoundRobinFairness {
  /// Rotates so the profile after `lastServed` leads; order is otherwise preserved. An unknown or
  /// absent `lastServed` leaves the list alone — the next pass rotates from whoever is served now.
  public static func order(
    profilesWithDemand: [RunnerProfileID],
    lastServed: RunnerProfileID?
  ) -> [RunnerProfileID] {
    guard let lastServed, let index = profilesWithDemand.firstIndex(of: lastServed) else {
      return profilesWithDemand
    }
    let pivot = profilesWithDemand.index(after: index)
    return Array(profilesWithDemand[pivot...]) + Array(profilesWithDemand[..<pivot])
  }
}

/// One profile's ask for a scheduling pass.
public struct ProfileStartPlan: Sendable, Hashable {
  public var profileId: RunnerProfileID
  public var plan: DesiredPlan
  public var request: ResourceRequest

  public init(profileId: RunnerProfileID, plan: DesiredPlan, request: ResourceRequest) {
    self.profileId = profileId
    self.plan = plan
    self.request = request
  }
}

public struct StartDecision: Sendable, Hashable {
  public var profileId: RunnerProfileID
  public var count: Int

  public init(profileId: RunnerProfileID, count: Int) {
    self.profileId = profileId
    self.count = count
  }
}

public struct AllocationResult: Sendable, Hashable {
  public var decisions: [StartDecision]
  /// Feed back into the next pass to keep the rotation moving.
  public var lastServed: RunnerProfileID?

  public init(decisions: [StartDecision], lastServed: RunnerProfileID?) {
    self.decisions = decisions
    self.lastServed = lastServed
  }

  public var totalStarts: Int {
    decisions.reduce(0) { $0 + $1.count }
  }
}

/// Hands out start slots one at a time so no profile can take the whole host in a single pass.
public enum Allocator {
  public static func allocate(
    plans: [ProfileStartPlan],
    reservations: [Reservation],
    budget: HostBudget,
    throttle: Int,
    lastServed: RunnerProfileID?
  ) -> AllocationResult {
    var pass = Pass(plans: plans, reservations: reservations, lastServed: lastServed)
    var budgetLeft = max(0, throttle)
    while budgetLeft > 0 {
      var progressed = false
      for profileId in pass.order where budgetLeft > 0 {
        guard pass.wants(profileId), let request = pass.requests[profileId] else { continue }
        // Simulated reservations only ever grow, so a profile that misses once cannot fit later.
        guard CapacityCalculator.fits(
          request: request, reservations: pass.simulated, budget: budget
        ).isFit else {
          pass.block(profileId)
          continue
        }
        pass.grant(profileId, request: request)
        budgetLeft -= 1
        progressed = true
      }
      if !progressed { break }
    }
    return pass.result()
  }

  /// Mutable bookkeeping for one `allocate` call, kept out of the loop for readability.
  private struct Pass {
    var order: [RunnerProfileID]
    var requests: [RunnerProfileID: ResourceRequest] = [:]
    var remaining: [RunnerProfileID: Int] = [:]
    var granted: [RunnerProfileID: Int] = [:]
    var blocked: Set<RunnerProfileID> = []
    var simulated: [Reservation]
    var served: RunnerProfileID?
    var sequence = 0

    init(plans: [ProfileStartPlan], reservations: [Reservation], lastServed: RunnerProfileID?) {
      var demand: [RunnerProfileID] = []
      var requests: [RunnerProfileID: ResourceRequest] = [:]
      var remaining: [RunnerProfileID: Int] = [:]
      // First plan wins for a duplicated profile id, so the pass stays a function of its input.
      for plan in plans where plan.plan.toStart > 0 && requests[plan.profileId] == nil {
        requests[plan.profileId] = plan.request
        remaining[plan.profileId] = plan.plan.toStart
        demand.append(plan.profileId)
      }
      self.requests = requests
      self.remaining = remaining
      order = RoundRobinFairness.order(profilesWithDemand: demand, lastServed: lastServed)
      simulated = reservations
      served = lastServed
    }

    func wants(_ profileId: RunnerProfileID) -> Bool {
      (remaining[profileId] ?? 0) > 0 && !blocked.contains(profileId)
    }

    mutating func block(_ profileId: RunnerProfileID) {
      blocked.insert(profileId)
    }

    mutating func grant(_ profileId: RunnerProfileID, request: ResourceRequest) {
      simulated.append(.simulated(request: request, profileId: profileId, sequence: sequence))
      sequence += 1
      granted[profileId, default: 0] += 1
      remaining[profileId] = (remaining[profileId] ?? 0) - 1
      served = profileId
    }

    func result() -> AllocationResult {
      let decisions = order.compactMap { profileId in
        granted[profileId].map { StartDecision(profileId: profileId, count: $0) }
      }
      return AllocationResult(decisions: decisions, lastServed: served)
    }
  }
}
