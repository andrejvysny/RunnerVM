import DaemonAPI
import Foundation
import GuestControl
import ImageStore
import Logging
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Phase D8: pinned maintenance instances. They hold real host capacity but are invisible to
/// demand, so the scheduler can never plan, cancel, reap, recycle or staff one — and the only
/// thing that ever reclaims one is its own ttl.
@Suite struct MaintenanceInstanceTests {
  private static let clock = Date(timeIntervalSince1970: 1_756_000_000)

  /// A pinned instance in the state a `vm create --pinned` leaves it in before any guest agent
  /// answers: `waitingForAgent`, which for a runner is the *cheapest* thing to cancel.
  private func pin(
    _ harness: M2Harness, profile: String = "linux", ttl: TimeInterval = 900,
    imageOverride: String? = nil
  ) async throws -> InstanceRecord {
    try await harness.instances.create(
      profileName: profile,
      options: InstanceCreateOptions(
        purpose: .maintenance, pinnedUntil: Date().addingTimeInterval(ttl),
        imageOverride: imageOverride))
  }

  // MARK: - Demand invisibility

  /// The control is the whole point: the same tick that takes an ordinary `vm create` VM away as
  /// surplus must leave the pinned one exactly where it is, repeatedly.
  @Test func scaleToZeroCancelsAPlainInstanceAndNeverThePinnedOne() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let pinned = try await pin(harness)
      let plain = try await harness.instances.create(profileName: "linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual)

      for _ in 0..<5 {
        await orchestrator.tick()
        await orchestrator.drainStarts()
      }

      #expect(try await harness.record(plain.id).state == .deleted)
      #expect(try await harness.record(pinned.id).state != .deleted)
      #expect(try await harness.record(pinned.id).purpose == .maintenance)
      // And it was never reported as a cancellation, so nothing even considered it.
      let cancelled = await orchestrator.recentEvents().compactMap { record -> String? in
        guard case .instanceCancelled(_, let instance, _) = record.event else { return nil }
        return instance
      }
      #expect(cancelled == [plain.id.rawValue])
    }
  }

  /// `reapExpiredIdle` measures an idle VM's age against `warmPool.idleTTL`. With the clock an
  /// hour past the pin's creation, an unpinned idle VM of the same profile would be long gone.
  @Test func theIdleTTLReaperNeverTouchesAPinnedInstance() async throws {
    let config = M2Harness.configuration(warmPool: WarmPoolPolicy(minIdle: 0, maxIdle: 0,
                                                                  idleTTL: .minutes(1)))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let pinned = try await pin(harness)
      let agent = try await harness.startGuestAgent(for: pinned.id)
      try await harness.awaitInstance(pinned.id, state: .idle)
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      // An hour after every instance in this test was created: far past the one-minute idle ttl.
      let future = Date().addingTimeInterval(3_600)
      let orchestrator = await harness.orchestrator(
        demand: manual, configuration: config, now: { future })

      for _ in 0..<3 { await orchestrator.tick() }

      #expect(try await harness.record(pinned.id).state == .idle)
      await agent.stop()
    }
  }

  /// `recycleRetiredIdle` removes any idle VM armed to retire. A pinned one stays: the operator
  /// asked for this VM to be here, and only the ttl may take it back.
  @Test func retiredAndTaintedFlagsDoNotRecycleAPinnedInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let pinned = try await pin(harness)
      let agent = try await harness.startGuestAgent(for: pinned.id)
      try await harness.awaitInstance(pinned.id, state: .idle)
      // Written straight to the row: `InstanceManager.taint` recycles an idle VM on the spot,
      // which is the operator path, not the scheduler path this test is about.
      _ = try await harness.instanceRows.applyReuse(
        id: pinned.id,
        ReuseUpdate(tainted: true, taintReason: "MANUAL", retireAfterSession: true))
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 0)
      let orchestrator = await harness.orchestrator(demand: manual)

      for _ in 0..<3 { await orchestrator.tick() }

      #expect(try await harness.record(pinned.id).state == .idle)
      await agent.stop()
    }
  }

  /// The pinned VM is idle and demand is real, so it is exactly what `assignSessions` would grab.
  /// It must not: a JIT registration on a smoke-test VM would hand GitHub a runner nobody meant
  /// to offer. The demand is served by starting another VM instead.
  @Test func aPinnedInstanceIsNeverHandedARunnerSession() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      try await harness.importLinuxImage()
      try await harness.registerScaleSet(profile: "linux", githubScaleSetId: 777)
      let profile = try await harness.profileID("linux")
      let pinned = try await pin(harness)
      let agent = try await harness.startGuestAgent(for: pinned.id)
      try await harness.awaitInstance(pinned.id, state: .idle)
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      await orchestrator.tick()

      #expect(try await harness.runners.list().isEmpty)
      #expect(harness.scaleSetPlane.jitCalls().isEmpty)
      #expect(try await harness.record(pinned.id).state == .idle)
      // The job was not simply dropped: the pass started a real runner VM for it.
      let started = try await harness.instanceRows.list(profile: profile, states: nil)
        .filter { $0.purpose == .runner && $0.state != .deleted }
      #expect(started.count == 1)
      await agent.stop()
    }
  }

  // MARK: - Resource visibility

  /// The other half of the contract: the pin costs the host a real slot, so the profile admits
  /// one fewer runner and advertises one fewer to GitHub while it runs.
  @Test func aPinnedInstanceStillConsumesProfileCapacity() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      // Baseline: an empty host advertises the profile's full ceiling.
      await orchestrator.tick()
      await orchestrator.drainStarts()
      #expect(await manual.advertisedCapacity(profile: profile) == 2)
      for record in try await harness.instanceRows.list(profile: profile, states: nil) {
        _ = try await harness.instances.delete(id: record.id)
      }

      _ = try await pin(harness)
      await orchestrator.tick()
      await orchestrator.drainStarts()

      // One slot is held by the pin, so only one runner may exist and only one is advertised.
      #expect(await manual.advertisedCapacity(profile: profile) == 1)
      let live = try await harness.instanceRows.list(profile: profile, states: nil)
        .filter { $0.state != .deleted }
      #expect(live.count { $0.purpose == .maintenance } == 1)
      #expect(live.count { $0.purpose == .runner } == 1)
    }
  }

  // MARK: - TTL reaper

  @Test func theReaperDeletesAPinnedInstanceOnceItsTTLHasPassed() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let deadline = Date().addingTimeInterval(600)
      let pinned = try await harness.instances.create(
        profileName: "linux",
        options: InstanceCreateOptions(purpose: .maintenance, pinnedUntil: deadline))
      let stream = await harness.events.subscribe()

      let early = MaintenanceInstanceReaper(
        instances: harness.instanceRows, manager: harness.instances, events: harness.events,
        now: { deadline.addingTimeInterval(-1) }, logger: Logger(label: "test"))
      #expect(try await early.run(firstTick: false).swept == 0)
      #expect(try await harness.record(pinned.id).state != .deleted)

      let late = MaintenanceInstanceReaper(
        instances: harness.instanceRows, manager: harness.instances, events: harness.events,
        now: { deadline.addingTimeInterval(1) }, logger: Logger(label: "test"))
      #expect(try await late.run(firstTick: false).swept == 1)
      #expect(try await harness.record(pinned.id).state == .deleted)

      // The event is already buffered by the time `run` returned, so this cannot hang on a race.
      let event = try await withHangGuard("the maintenanceExpired event") {
        for await event in stream
        where event.name == LifecycleEventLog.instanceMaintenanceExpired {
          return event
        }
        throw WaitTimeout(description: "the event stream closed first")
      }
      #expect(event.fields.instance == pinned.id)

      // Idempotent: a second sweep finds nothing left to reap.
      #expect(try await late.run(firstTick: false).swept == 0)
    }
  }

  @Test func theReaperLeavesRunnerInstancesAndUnexpiredPinsAlone() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let runner = try await harness.instances.create(profileName: "linux")
      let pinned = try await pin(harness, ttl: 3_600)
      let reaper = MaintenanceInstanceReaper(
        instances: harness.instanceRows, manager: harness.instances, events: harness.events,
        now: { Date() }, logger: Logger(label: "test"))

      #expect(try await reaper.run(firstTick: false).swept == 0)
      #expect(try await harness.record(runner.id).state != .deleted)
      #expect(try await harness.record(pinned.id).state != .deleted)
    }
  }

  // MARK: - Image override

  @Test func anImageOverrideIsWhatThePinnedInstanceBootsAndPins() async throws {
    try await withHarness { harness in
      let profileImage = try await harness.importLinuxImage()
      let candidate = try await harness.importAlternateLinuxImage()
      #expect(candidate.record.digest != profileImage.record.digest)

      let pinned = try await pin(harness, imageOverride: M2Harness.alternateLinuxImageName)

      #expect(pinned.imageDigest == candidate.record.digest)
      // The permanent `instance` pin followed the override, not the profile's image.
      let pins = try await harness.imageRows.pins(ownerType: .instance)
      #expect(pins.contains {
        $0.ownerId == pinned.id.rawValue && $0.digest == candidate.record.digest
      })
      #expect(try await harness.imageRows.pinCount(digest: profileImage.record.digest) == 0)
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
    }
  }

  // MARK: - Handler validation

  /// The wire code the handler would answer with. `DaemonServiceError` is not a `RunnerError`, so
  /// both shapes have to be unwrapped to compare against a documented code.
  private func createCode(
    _ harness: M2Harness, _ request: InstanceCreateRequest
  ) async -> String? {
    do {
      _ = try await harness.service().instanceCreate(request)
      return nil
    } catch let error as any RunnerError {
      return error.code
    } catch let error as DaemonServiceError {
      return error.code
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }

  @Test func aMaintenanceCreateWithoutATTLIsRefused() async throws {
    try await withHarness { harness in
      let code = await createCode(
        harness, InstanceCreateRequest(profile: "linux", purpose: "maintenance"))
      #expect(code == "MAINTENANCE_TTL_REQUIRED")
    }
  }

  @Test func aMaintenanceTTLOutsideTheBoundsIsRefused() async throws {
    try await withHarness { harness in
      for ttl in [Int64(0), MaintenanceTTL.minimumMs - 1, MaintenanceTTL.maximumMs + 1] {
        let code = await createCode(
          harness,
          InstanceCreateRequest(profile: "linux", purpose: "maintenance", ttlMs: ttl))
        #expect(code == "MAINTENANCE_TTL_INVALID", "ttl \(ttl)")
      }
    }
  }

  @Test func anImageOverrideOnARunnerCreateIsRefused() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let code = await createCode(
        harness,
        InstanceCreateRequest(profile: "linux", imageOverride: M2Harness.linuxImageName))
      #expect(code == "IMAGE_OVERRIDE_MAINTENANCE_ONLY")
      #expect(try await harness.instanceRows.list(profile: nil, states: nil).isEmpty)
    }
  }

  /// An unknown purpose is an error rather than a silent downgrade to `runner`: quietly handing
  /// back an ordinary VM the scheduler will cancel is worse than saying no.
  @Test func anUnknownPurposeIsRefused() async throws {
    try await withHarness { harness in
      let code = await createCode(
        harness, InstanceCreateRequest(profile: "linux", purpose: "qualification"))
      #expect(code == DaemonErrorCode.notFound)
    }
  }

  /// `createOptions` is where `ttlMs` becomes an absolute deadline, so the arithmetic is pinned
  /// here rather than inferred from a row a boot had to produce.
  @Test func theTTLBecomesAnAbsoluteDeadline() throws {
    let options = try DaemonServiceImpl.createOptions(
      InstanceCreateRequest(
        profile: "linux", purpose: "maintenance", ttlMs: 900_000, imageOverride: "sha256:a"),
      now: Self.clock)
    #expect(options.purpose == .maintenance)
    #expect(options.pinnedUntil == Self.clock.addingTimeInterval(900))
    #expect(options.imageOverride == "sha256:a")
    #expect(try DaemonServiceImpl.createOptions(
      InstanceCreateRequest(profile: "linux"), now: Self.clock) == .runner)
  }

  // MARK: - Host mode

  /// `instance.create` is the debug surface and has never been gated on `hosts.mode`; a pinned
  /// create must not invent a gate of its own. What draining does change is the scheduler, and it
  /// changes it for the pinned VM exactly as for any other: nothing is advertised, nothing starts.
  @Test func drainingTreatsAPinnedCreateExactlyLikeAnOrdinaryOne() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      try await harness.hosts.setMode(id: harness.hostId, from: .normal, to: .draining)
      let profile = try await harness.profileID("linux")

      let plain = try await harness.service().instanceCreate(
        InstanceCreateRequest(profile: "linux"))
      let pinned = try await harness.service().instanceCreate(
        InstanceCreateRequest(profile: "linux", purpose: "maintenance", ttlMs: 900_000))
      #expect(!plain.isMaintenance)
      #expect(pinned.isMaintenance)
      #expect(pinned.pinnedUntil != nil)

      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual)
      await orchestrator.tick()
      await orchestrator.drainStarts()

      #expect(await manual.advertisedCapacity(profile: profile) == 0)
      let live = try await harness.instanceRows.list(profile: profile, states: nil)
        .filter { $0.state != .deleted }
      #expect(live.count == 2)
    }
  }

  // MARK: - instance.selfTest

  @Test func selfTestRelaysTheGuestAnswerThroughTheDaemon() async throws {
    try await withHarness { harness in
      let checks = SelfTestResult(checks: [
        SelfTestCheck(name: "keychain.create", ok: true),
        SelfTestCheck(name: "codesign.sign", ok: false, detail: "no identity"),
      ])
      let (record, agent) = try await harness.idleInstance()
      await agent.setSelfTest(checks)

      let result = try await harness.service().instanceSelfTest(
        InstanceSelfTestRequest(id: record.id.rawValue))

      #expect(result == checks)
      #expect(!result.passed)
      #expect(await agent.callCount(.selfTest) == 1)
      await agent.stop()
    }
  }

  /// Same gate as `instance.metrics`: without a completed handshake the caller must be told the
  /// agent is not ready rather than handed a transport error from a bridge that hangs up.
  @Test func selfTestBeforeTheHandshakeReportsTheAgentNotReady() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await #expect(throws: GuestAgentError.self) {
        try await harness.service().instanceSelfTest(
          InstanceSelfTestRequest(id: record.id.rawValue))
      }
    }
  }
}
