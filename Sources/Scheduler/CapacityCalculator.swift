import Foundation
import RunnerCore

/// Why a request was refused. All applicable reasons are reported so an operator sees the whole
/// picture, in a fixed order (cpu, memory, disk, maxVMs, macOS cap) for deterministic output.
public enum FitRejection: Sendable, Hashable {
  case cpu(needed: Int, available: Double)
  case memory(needed: UInt64, available: UInt64)
  case disk(needed: UInt64, available: UInt64)
  case maxVMs(limit: Int)
  case macOSGuestLimit(limit: Int)
}

public enum FitResult: Sendable, Hashable {
  case fits
  case rejected([FitRejection])

  public var isFit: Bool {
    if case .fits = self { true } else { false }
  }

  public var rejections: [FitRejection] {
    if case let .rejected(reasons) = self { reasons } else { [] }
  }
}

public extension FitRejection {
  /// Mapping to the shared error type so callers can surface admission failures over RPC.
  /// `nil` for `maxVMs`: `SchedulerError` has no host-wide VM-count case and inventing one of the
  /// existing cases would report a wrong cause.
  var schedulerError: SchedulerError? {
    switch self {
    case let .cpu(needed, available):
      .insufficientCPU(requested: needed, availableBudget: Int(max(0, available).rounded(.down)))
    case let .memory(needed, available):
      .insufficientMemory(requestedBytes: needed, availableBytes: available)
    case let .disk(needed, available):
      .insufficientDisk(requestedBytes: needed, availableBytes: available)
    case .maxVMs:
      nil
    case let .macOSGuestLimit(limit):
      .macOSGuestLimitReached(limit: limit)
    }
  }
}

public enum LimitingFactor: Sendable, Hashable {
  case none
  case cpu
  case memory
  case disk
  case maxVMs
  case macOSGuestLimit
  case profileMaxInstances
  case hostMode

  init(_ rejection: FitRejection?) {
    switch rejection {
    case .cpu: self = .cpu
    case .memory: self = .memory
    case .disk: self = .disk
    case .maxVMs: self = .maxVMs
    case .macOSGuestLimit: self = .macOSGuestLimit
    case nil: self = .none
    }
  }
}

/// How many more instances of one profile the host could take right now.
public struct ProfileCapacity: Sendable, Hashable {
  /// Additional instances beyond the ones already reserved.
  public var cap: Int
  public var limitingFactor: LimitingFactor
  public var currentInstances: Int

  public init(cap: Int, limitingFactor: LimitingFactor, currentInstances: Int) {
    self.cap = cap
    self.limitingFactor = limitingFactor
    self.currentInstances = currentInstances
  }

  /// Total instances this profile could hold — what `X-ScaleSetMaxCapacity` reports.
  public var total: Int {
    currentInstances + cap
  }
}

/// Pure admission arithmetic (spec §16, §17; plan C1 "Capacity"). No I/O, no clock.
public enum CapacityCalculator {
  /// vCPU budgets are `Int × Double`, so an exact-fit comparison must tolerate representation
  /// error; 1e-9 cannot admit an extra whole vCPU.
  static let cpuEpsilon = 1e-9

  /// A request that consumes nothing in any bounded dimension would loop forever in
  /// `profileCapacity`; bound the probe instead of trapping.
  static let degenerateProbeCeiling = 1024

  public static func fits(
    request: ResourceRequest,
    reservations: [Reservation],
    budget: HostBudget
  ) -> FitResult {
    let totals = Totals(reservations)
    var reasons: [FitRejection] = []

    let neededCPU = max(0, request.cpuCount)
    let availableCPU = budget.cpuBudget - Double(totals.cpu)
    if Double(neededCPU) > availableCPU + cpuEpsilon {
      reasons.append(.cpu(needed: neededCPU, available: availableCPU))
    }

    let availableMemory = SaturatingMath.sub(budget.memoryBudgetBytes, totals.memory)
    if request.memoryBytes > availableMemory {
      reasons.append(.memory(needed: request.memoryBytes, available: availableMemory))
    }

    let availableDisk = SaturatingMath.sub(budget.diskBudgetBytes, totals.disk)
    if request.diskReservationBytes > availableDisk {
      reasons.append(.disk(needed: request.diskReservationBytes, available: availableDisk))
    }

    if let limit = budget.maxVMs, totals.count >= limit {
      reasons.append(.maxVMs(limit: limit))
    }

    if request.guestOS == .macos, totals.macOS >= HostConstants.macOSGuestLimit {
      reasons.append(.macOSGuestLimit(limit: HostConstants.macOSGuestLimit))
    }

    return reasons.isEmpty ? .fits : .rejected(reasons)
  }

  public static func profileCapacity(
    profileId: RunnerProfileID,
    profile: RunnerProfileConfig,
    reservations: [Reservation],
    budget: HostBudget,
    hostMode: HostMode
  ) -> ProfileCapacity {
    let current = reservations.count { $0.profileId == profileId }
    guard hostMode.admitsNewWork else {
      return ProfileCapacity(cap: 0, limitingFactor: .hostMode, currentInstances: current)
    }
    let headroom = profile.limits.maxInstances.map { max(0, $0 - current) }
    if headroom == 0 {
      return ProfileCapacity(
        cap: 0, limitingFactor: .profileMaxInstances, currentInstances: current
      )
    }
    let request = ResourceRequest(profile: profile)
    let probe = probeFit(
      request: request, profileId: profileId, reservations: reservations, budget: budget,
      ceiling: ceiling(for: request, headroom: headroom, budget: budget)
    )
    let factor = probe.rejection.map(LimitingFactor.init)
      ?? (headroom == probe.cap ? .profileMaxInstances : .none)
    return ProfileCapacity(cap: probe.cap, limitingFactor: factor, currentInstances: current)
  }

  /// `X-ScaleSetMaxCapacity`: the total this profile could reach, zero while draining (spec §109).
  public static func advertisedCapacity(
    profileId: RunnerProfileID,
    profile: RunnerProfileConfig,
    reservations: [Reservation],
    budget: HostBudget,
    hostMode: HostMode
  ) -> Int {
    guard hostMode.advertisesCapacity else { return 0 }
    let capacity = profileCapacity(
      profileId: profileId, profile: profile, reservations: reservations,
      budget: budget, hostMode: hostMode
    )
    return capacity.total
  }

  // MARK: - Internals

  /// Repeated `fits` against a growing simulated set, so capacity can never disagree with
  /// admission.
  static func probeFit(
    request: ResourceRequest,
    profileId: RunnerProfileID,
    reservations: [Reservation],
    budget: HostBudget,
    ceiling: Int
  ) -> (cap: Int, rejection: FitRejection?) {
    var simulated = reservations
    var cap = 0
    while cap < ceiling {
      switch fits(request: request, reservations: simulated, budget: budget) {
      case .fits:
        simulated.append(.simulated(request: request, profileId: profileId, sequence: cap))
        cap += 1
      case let .rejected(reasons):
        return (cap, reasons.first)
      }
    }
    return (cap, nil)
  }

  private static func ceiling(for request: ResourceRequest, headroom: Int?, budget: HostBudget)
    -> Int
  {
    if let headroom { return headroom }
    let consumesNothing = request.cpuCount <= 0
      && request.memoryBytes == 0
      && request.diskReservationBytes == 0
    let bounded = !consumesNothing || budget.maxVMs != nil || request.guestOS == .macos
    return bounded ? Int.max : degenerateProbeCeiling
  }

  struct Totals {
    var cpu = 0
    var memory: UInt64 = 0
    var disk: UInt64 = 0
    var count = 0
    var macOS = 0

    init(_ reservations: [Reservation]) {
      for reservation in reservations {
        cpu += max(0, reservation.cpuCount)
        memory = SaturatingMath.add(memory, reservation.memoryBytes)
        disk = SaturatingMath.add(disk, reservation.diskReservationBytes)
        count += 1
        if reservation.guestOS == .macos { macOS += 1 }
      }
    }
  }
}
