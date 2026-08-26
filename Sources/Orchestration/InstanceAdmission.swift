import Foundation
import ImageStore
import Persistence
import RunnerCore
import Scheduler

/// Host-budget admission for one new instance (spec §121): the profile's own cap first, then the
/// capacity calculator against every row that still holds a reservation.
///
/// Split out of `InstanceManager` because it needs nothing from the lifecycle ladder — only the
/// repositories, the host facts and the applied configuration. The two statics are the shared
/// definition of "what the host is currently committed to"; `Orchestrator` plans against exactly
/// the same numbers admission will later enforce.
struct InstanceAdmission {
  let paths: RunnerPaths
  let instances: any InstanceRepository
  let profiles: any ProfileRepository
  let probe: HostProbeResult
  let configuration: RunnerConfiguration?

  func admit(
    profile: RunnerProfileConfig, profileId: RunnerProfileID, reservationBytes: UInt64
  ) async throws {
    let reservations = try await Self.reservations(instances: instances, profiles: profiles)
    if let limit = profile.limits.maxInstances,
       reservations.count(where: { $0.profileId == profileId }) >= limit {
      throw SchedulerError.profileAtMaxInstances(profile: profile.name, limit: limit)
    }
    let budget = Self.budget(configuration: configuration, probe: probe, paths: paths)
    let request = ResourceRequest(profile: profile, diskReservationBytes: reservationBytes)
    switch CapacityCalculator.fits(request: request, reservations: reservations, budget: budget) {
    case .fits:
      return
    case .rejected(let reasons):
      if let error = reasons.compactMap(\.schedulerError).first { throw error }
      throw OrchestrationError.capacityRejected(reasons: reasons.map { "\($0)" })
    }
  }

  static func budget(
    configuration: RunnerConfiguration?, probe: HostProbeResult, paths: RunnerPaths
  ) -> HostBudget {
    HostBudget(
      config: configuration?.host ?? HostConfig(),
      resources: HostResources(
        logicalCPUs: probe.facts.logicalCPUCount,
        physicalMemoryBytes: probe.facts.physicalMemoryBytes,
        freeDiskBytes: APFSClone.freeSpace(at: paths.instancesDir)))
  }

  /// Every non-`deleted` row still holds its cpu/memory/disk against the host budget (spec §121).
  ///
  /// `bound` is the set of instances a runner session has claimed. The scheduler may never cancel
  /// one of those — a JIT config has been issued against it and tearing the VM down would strand a
  /// runner registration on GitHub (plan C1 "Cancellation").
  static func reservations(
    instances: any InstanceRepository, profiles: any ProfileRepository,
    bound: Set<InstanceID> = []
  ) async throws -> [Reservation] {
    let guestOS = Dictionary(
      try await profiles.list().map { ($0.id, $0.guestOS) }, uniquingKeysWith: { first, _ in first })
    return try await instances.list(profile: nil, states: nil)
      .filter { $0.state.consumesCapacity }
      .map { record in
        Reservation(
          instanceId: record.id, profileId: record.profileId,
          guestOS: guestOS[record.profileId] ?? .linux, cpuCount: record.cpuCount,
          memoryBytes: record.memoryBytes, diskReservationBytes: record.diskReservationBytes,
          state: record.state, bound: bound.contains(record.id), createdAt: record.createdAt.date)
      }
  }
}
