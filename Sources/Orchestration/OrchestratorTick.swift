import Foundation
import Persistence
import RunnerCore
import RunnerLogging
import Scheduler

/// One scheduling pass, computed once so every decision in it sees the same host (spec §105).
struct SchedulingPass: Sendable {
  struct ProfileEntry: Sendable {
    var id: RunnerProfileID
    var name: String
    var config: RunnerProfileConfig
    var plan: DesiredPlan
    var request: ResourceRequest
    var assignedJobs: Int
    /// `plan.toStart` after the in-flight creations and the hold-down are taken off.
    var startable: Int
    /// `DemandSnapshot.confirmed`: only a confirmed demand figure may take a VM away.
    var demandConfirmed: Bool
  }

  var config: RunnerConfiguration
  var mode: HostMode
  var budget: HostBudget
  var reservations: [Reservation]
  var instances: [InstanceRecord]
  var bound: Set<InstanceID>
  var activeSessions: [RunnerProfileID: Int]
  var profiles: [ProfileEntry]
}

/// The tick itself. Split out of `Orchestrator.swift` to keep that file under its line budget;
/// every member below runs actor-isolated on `Orchestrator` exactly as if it were declared there.
extension Orchestrator {
  /// Idempotent by construction (spec §69): it plans from persisted rows, never from a delta.
  public func tick() async {
    // Guarded on `stopped`, not on `started`: a tick is idempotent and safe before the event pump
    // exists, but it must never start a VM while the daemon is shutting down (spec §108).
    guard !stopped else { return }
    await demand.refresh()
    guard let pass = await buildPass() else { return }
    await refreshMetrics(pass)
    await startInstances(pass)
    await cancelInstances(pass)
    await assignSessions(pass)
    await recycleRetiredIdle(pass)
    await reapExpiredIdle(pass)
  }

  // MARK: - Pass construction

  private func buildPass() async -> SchedulingPass? {
    let config = configuration ?? RunnerConfiguration()
    let mode = (try? await hosts.mode(id: hostId)) ?? .normal
    guard let rows = try? await profiles.list(),
          let records = try? await instanceRows.list(profile: nil, states: nil)
    else { return nil }
    let live = ((try? await sessionRows.list(limit: nil)) ?? []).filter { !$0.state.isTerminal }
    let bound = Set(live.map(\.instanceId))
    guard let reservations = try? await InstanceAdmission.reservations(
      instances: instanceRows, profiles: profiles, bound: bound, builds: imageBuilds)
    else { return nil }
    let budget = InstanceAdmission.budget(configuration: config, probe: probe, paths: paths)
    var entries: [SchedulingPass.ProfileEntry] = []
    for row in rows where row.enabled {
      guard let entry = await entry(row, reservations: reservations, budget: budget, mode: mode)
      else { continue }
      entries.append(entry)
    }
    var active: [RunnerProfileID: Int] = [:]
    for session in live { active[session.profileId, default: 0] += 1 }
    return SchedulingPass(
      config: config, mode: mode, budget: budget, reservations: reservations, instances: records,
      bound: bound, activeSessions: active, profiles: entries)
  }

  /// Advertises this profile's capacity and turns GitHub's `assignedJobs` into a desired plan.
  private func entry(
    _ row: RunnerProfileRecord, reservations: [Reservation], budget: HostBudget, mode: HostMode
  ) async -> SchedulingPass.ProfileEntry? {
    guard let profile = try? row.decodedConfig() else { return nil }
    let capacity = CapacityCalculator.profileCapacity(
      profileId: row.id, profile: profile, reservations: reservations, budget: budget,
      hostMode: mode)
    let advertised = CapacityCalculator.advertisedCapacity(
      profileId: row.id, profile: profile, reservations: reservations, budget: budget,
      hostMode: mode)
    await demand.advertise(profile: row.id, capacity: advertised)
    if lastAdvertised[row.id] != advertised {
      lastAdvertised[row.id] = advertised
      note(.capacityAdvertised(profile: row.name, capacity: advertised))
    }
    let snapshot = await demand.snapshot(profile: row.id)
    let plan = DesiredCapacity.compute(
      profile: profile, assignedJobs: snapshot.assignedJobs,
      reservations: reservations.filter { $0.profileId == row.id }, capacity: capacity)
    let inFlight = starting[row.id] ?? 0
    let startable = mode.admitsNewWork && !isHeldDown(row.id)
      ? max(0, plan.toStart - inFlight) : 0
    demandState[row.id] = ProfileDemandState(
      assignedJobs: snapshot.assignedJobs, advertisedCapacity: advertised, starting: inFlight,
      healthy: snapshot.healthy)
    return SchedulingPass.ProfileEntry(
      id: row.id, name: row.name, config: profile, plan: plan,
      request: ResourceRequest(profile: profile), assignedJobs: snapshot.assignedJobs,
      startable: startable, demandConfirmed: snapshot.confirmed)
  }

  // MARK: - Starts (spec §106, §136)

  private func startInstances(_ pass: SchedulingPass) async {
    let plans = pass.profiles.filter { $0.startable > 0 }.map { entry in
      ProfileStartPlan(
        profileId: entry.id,
        plan: DesiredPlan(
          busyTarget: entry.plan.busyTarget, idleTarget: entry.plan.idleTarget,
          toStart: entry.startable, toCancel: []),
        request: entry.request)
    }
    guard !plans.isEmpty else { return }
    let allowed = StartupThrottle.allowedStarts(
      pending: plans.reduce(0) { $0 + $1.plan.toStart },
      inFlightStarts: starting.values.reduce(0, +),
      limit: pass.config.host.limits.concurrentVMStarts)
    guard allowed > 0 else { return }
    let result = Allocator.allocate(
      plans: plans, reservations: pass.reservations, budget: pass.budget, throttle: allowed,
      lastServed: lastServed)
    lastServed = result.lastServed
    let names = Dictionary(
      pass.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for decision in result.decisions {
      for _ in 0..<decision.count {
        launchStart(decision.profileId, name: names[decision.profileId] ?? decision.profileId.rawValue)
      }
    }
  }

  /// Detached on purpose: `create` walks the clone/spawn/boot ladder, and a reconcile tick that
  /// waited for it would stall worker recovery behind a slow image.
  private func launchStart(_ profileId: RunnerProfileID, name: String) {
    let token = nextStartToken
    nextStartToken += 1
    starting[profileId, default: 0] += 1
    startTasks[token] = Task { [weak self] in
      await self?.performStart(profileId, name: name)
      await self?.finishStart(token, profile: profileId)
    }
  }

  private func performStart(_ profileId: RunnerProfileID, name: String) async {
    do {
      let record = try await instances.create(profileName: name)
      note(.instanceStarted(profile: name, instance: record.id.rawValue))
    } catch {
      let reason = Self.describe(error)
      holdDown[profileId] = now().addingTimeInterval(Double(tuning.startHoldDown.components.seconds))
      note(.instanceStartFailed(profile: name, reason: reason))
    }
  }

  private func finishStart(_ token: Int, profile: RunnerProfileID) {
    startTasks[token] = nil
    starting[profile] = max(0, (starting[profile] ?? 1) - 1)
    if starting[profile] == 0 { starting[profile] = nil }
  }

  private func isHeldDown(_ profileId: RunnerProfileID) -> Bool {
    guard let until = holdDown[profileId] else { return false }
    guard now() < until else {
      holdDown[profileId] = nil
      return false
    }
    return true
  }

  // MARK: - Cancellation (spec §107)

  private func cancelInstances(_ pass: SchedulingPass) async {
    for entry in pass.profiles {
      // Fail safe on a figure the message session has not confirmed yet (right after a restart):
      // starting is cheap to undo, cancelling a VM that is about to receive its job is not.
      guard entry.demandConfirmed else {
        if !entry.plan.toCancel.isEmpty {
          logger.info(
            "deferring cancellation until the scale set confirms demand",
            metadata: ["profile": .string(entry.name),
                       "candidates": .stringConvertible(entry.plan.toCancel.count)])
        }
        continue
      }
      for id in entry.plan.toCancel {
        await cancel(id, profile: entry.name, reason: "demand dropped")
      }
    }
  }

  /// Reaps warm instances that have outlived `idleTTL` (spec §127). Skipped while the profile has
  /// demand it has not served yet: an idle VM about to be handed a job is not stale.
  private func reapExpiredIdle(_ pass: SchedulingPass) async {
    for entry in pass.profiles {
      let ttl = entry.config.warmPool.idleTTL
      guard ttl.isPositive, entry.demandConfirmed,
            entry.assignedJobs <= (pass.activeSessions[entry.id] ?? 0)
      else { continue }
      for record in pass.instances
      where record.profileId == entry.id && record.state == .idle && !pass.bound.contains(record.id) {
        let since = record.agentReadyAt?.date ?? record.createdAt.date
        guard now().timeIntervalSince(since) >= Double(ttl.seconds) else { continue }
        await cancel(record.id, profile: entry.name, reason: "idle ttl")
      }
    }
  }

  /// Spec §126, §138: an idle VM that may not be trusted, or whose profile has moved to a new
  /// image digest, never receives another session. Removing it here is what lets the next tick
  /// start a clean replacement against the same demand.
  private func recycleRetiredIdle(_ pass: SchedulingPass) async {
    let names = Dictionary(
      pass.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for record in pass.instances
    where record.state == .idle && (record.tainted || record.retireAfterSession)
      && !pass.bound.contains(record.id) {
      await cancel(
        record.id, profile: names[record.profileId] ?? record.profileId.rawValue,
        reason: record.tainted ? "tainted" : "retired")
    }
  }

  private func cancel(_ id: InstanceID, profile: String, reason: String) async {
    do {
      _ = try await instances.delete(id: id)
      note(.instanceCancelled(profile: profile, instance: id.rawValue, reason: reason))
    } catch {
      logger.warning(
        "could not cancel instance",
        metadata: .context(instance: id).merging([
          "reason": .string(reason), "error": .string(Self.describe(error)),
        ]) { $1 })
    }
  }

  // MARK: - Session hand-off (spec §48 steps 14-17)

  private func assignSessions(_ pass: SchedulingPass) async {
    guard pass.mode.admitsNewWork else { return }
    for entry in pass.profiles {
      var active = pass.activeSessions[entry.id] ?? 0
      guard entry.assignedJobs > active else { continue }
      let origin = await jitOrigin(entry.id)
      // Spec §126: a tainted or retiring VM never receives a session — `recycleRetiredIdle`
      // takes it away instead.
      let idle = pass.instances
        .filter {
          $0.profileId == entry.id && $0.state == .idle && !pass.bound.contains($0.id)
            && !$0.tainted && !$0.retireAfterSession
        }
        .sorted { $0.createdAt.date < $1.createdAt.date }
      for record in idle where entry.assignedJobs > active {
        guard await assign(record, profile: entry.name, origin: origin) else { break }
        active += 1
      }
    }
  }

  /// The scale set is read from the persisted row rather than from the demand provider, so a
  /// manual-demand daemon still issues scale-set JIT configs once a scale set exists.
  private func jitOrigin(_ profileId: RunnerProfileID) async -> RunnerSessionManager.JITOrigin {
    guard let record = try? await scaleSets.get(profileId: profileId),
          let id = record.githubScaleSetId
    else { return .rest }
    return .scaleSet(id: id)
  }

  private func assign(
    _ record: InstanceRecord, profile: String, origin: RunnerSessionManager.JITOrigin
  ) async -> Bool {
    do {
      let session = try await runners.startSession(instanceId: record.id, origin: origin)
      note(
        .sessionAssigned(
          profile: profile, instance: record.id.rawValue, session: session.id.rawValue))
      return true
    } catch {
      note(
        .sessionAssignmentFailed(
          profile: profile, instance: record.id.rawValue, reason: Self.describe(error)))
      return false
    }
  }
}
