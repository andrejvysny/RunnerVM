import Foundation
import GitHubControl
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging
import Scheduler

/// Turns demand into VMs and VMs into runner sessions (spec §15 as replaced by plan C1
/// "Capacity", §105, §106, §107, §121).
///
/// The actor owns no scheduling truth of its own: every pass re-reads the instance rows, the
/// session rows and the host mode, and every decision it makes is expressed as a repository
/// transition. Waking it early with an event is only an optimisation over the 10-second tick.
public actor Orchestrator {
  public struct Tuning: Sendable {
    /// How long a profile is skipped for starts after `InstanceManager.create` threw. Without it a
    /// profile whose image is missing would retry every tick forever (plan C1 "Capacity").
    public var startHoldDown: Duration = .seconds(30)
    /// Events kept for `system.status` / `runnerctl`.
    public var eventRingSize = 128

    public init() {}
  }

  let hostId: HostID
  let paths: RunnerPaths
  let probe: HostProbeResult
  let hosts: any HostRepository
  let profiles: any ProfileRepository
  let instanceRows: any InstanceRepository
  let sessionRows: any RunnerSessionRepository
  let scaleSets: any ScaleSetRepository
  let instances: InstanceManager
  let runners: RunnerSessionManager
  let demand: any DemandProvider
  let metrics: MetricRegistry
  let tuning: Tuning
  let now: @Sendable () -> Date
  let logger: Logger

  var configuration: RunnerConfiguration?
  var started = false
  var stopped = false
  var lastServed: RunnerProfileID?
  var starting: [RunnerProfileID: Int] = [:]
  var holdDown: [RunnerProfileID: Date] = [:]
  var lastAdvertised: [RunnerProfileID: Int] = [:]
  var demandState: [RunnerProfileID: ProfileDemandState] = [:]
  var startTasks: [Int: Task<Void, Never>] = [:]
  /// Previous `proc_pidinfo` reading per worker; CPU percent is a delta, not an absolute
  /// (spec §40).
  var workerCPU: [InstanceID: (cpuSeconds: Double, at: Date)] = [:]
  var nextStartToken = 0
  var events: [OrchestratorEventRecord] = []
  /// Capacity held by in-flight image builds, so a scheduling pass plans against the same host
  /// admission will enforce. `nil` until Phase 5 attaches a builder.
  var imageBuilds: (any ImageBuildReservationSource)?
  /// `logs/events.jsonl`. Attached after construction; see `InstanceManager.attachEventLog`.
  var eventLog: LifecycleEventLog?
  private var eventTask: Task<Void, Never>?

  public init(
    hostId: HostID,
    paths: RunnerPaths,
    probe: HostProbeResult,
    hosts: any HostRepository,
    profiles: any ProfileRepository,
    instanceRows: any InstanceRepository,
    sessionRows: any RunnerSessionRepository,
    scaleSets: any ScaleSetRepository,
    instances: InstanceManager,
    runners: RunnerSessionManager,
    demand: any DemandProvider,
    metrics: MetricRegistry = MetricRegistry(),
    tuning: Tuning = Tuning(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .scheduler)
  ) {
    self.hostId = hostId
    self.paths = paths
    self.probe = probe
    self.hosts = hosts
    self.profiles = profiles
    self.instanceRows = instanceRows
    self.sessionRows = sessionRows
    self.scaleSets = scaleSets
    self.instances = instances
    self.runners = runners
    self.demand = demand
    self.metrics = metrics
    self.tuning = tuning
    self.now = now
    self.logger = logger
  }

  // MARK: - Lifecycle

  public func start() async throws {
    guard !started else { return }
    started = true
    stopped = false
    try await demand.start()
    let stream = await demand.events
    eventTask = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        await self.receive(event)
      }
    }
  }

  public func stop() async {
    started = false
    stopped = true
    eventTask?.cancel()
    eventTask = nil
    await demand.stop()
    await drainStarts()
  }

  /// The demand provider is wired once at startup from whatever `github.demand` said then (spec
  /// §13); it is never hot-swapped, so a later `config.apply` that changes it only takes effect
  /// after the next `runnerd` restart. This just warns the operator rather than silently ignoring
  /// the change.
  public func updateConfiguration(_ config: RunnerConfiguration?) {
    if let previous = configuration?.github.demand, let next = config?.github.demand,
      previous != next
    {
      logger.warning(
        "github.demand changed; restart runnerd to switch the demand provider",
        metadata: ["from": .string(previous.rawValue), "to": .string(next.rawValue)])
    }
    configuration = config
  }

  /// Waits for the instance creations this orchestrator launched. Used by teardown and by tests
  /// that need the boot ladder to have finished before they assert.
  public func drainStarts() async {
    while let entry = startTasks.first {
      await entry.value.value
      startTasks[entry.key] = nil
    }
  }

  public func attachEventLog(_ log: LifecycleEventLog?) {
    eventLog = log
  }

  /// Phase 5 seam; see `InstanceManager.attachImageBuilds`.
  public func attachImageBuilds(_ source: (any ImageBuildReservationSource)?) {
    imageBuilds = source
  }

  // MARK: - Queries

  public func recentEvents(limit: Int = 50) -> [OrchestratorEventRecord] {
    Array(events.suffix(max(0, limit)))
  }

  public func state(profile: RunnerProfileID) -> ProfileDemandState {
    demandState[profile] ?? ProfileDemandState()
  }

  public func states() -> [RunnerProfileID: ProfileDemandState] {
    demandState
  }

  /// `scaleset.list`: what the provider knows, joined with the persisted scale-set rows so a
  /// profile that has a row but no live session still appears.
  public func demandReport() async -> [DemandProviderReport] {
    var byProfile = Dictionary(
      await demand.report().map { ($0.profileId, $0) }, uniquingKeysWith: { first, _ in first })
    for row in (try? await profiles.list()) ?? [] where row.enabled {
      guard let record = try? await scaleSets.get(profileId: row.id) else { continue }
      let snapshot = await demand.snapshot(profile: row.id)
      var report = byProfile[row.id]
        ?? DemandProviderReport(profileId: row.id, state: record.state, snapshot: snapshot)
      report.scaleSetName = report.scaleSetName ?? record.githubScaleSetName
      report.githubScaleSetId = report.githubScaleSetId ?? record.githubScaleSetId
      if report.sessionGeneration == nil,
         let session = try? await scaleSets.currentSession(scaleSetId: record.id) {
        report.sessionGeneration = session.sessionGeneration
        report.lastMessageId = session.lastMessageId
        report.sessionState = session.state
      }
      byProfile[row.id] = report
    }
    return byProfile.values.sorted { $0.profileId.rawValue < $1.profileId.rawValue }
  }

  public func setManualDemand(profile: RunnerProfileID, assignedJobs: Int) async throws {
    try await demand.setDemand(profile: profile, assignedJobs: assignedJobs)
    await tick()
  }

  // MARK: - Events

  /// Statistics moved, so the plan may have. Correlation events are recorded but do not schedule:
  /// a runner that started or finished changes GitHub's numbers, and the next snapshot rules
  /// (plan C1, "runner death mid-job ⇒ no local demand decrement").
  private func receive(_ event: DemandEvent) async {
    switch event {
    case let .demandChanged(profile):
      let snapshot = await demand.snapshot(profile: profile)
      note(.demandChanged(profile: profile.rawValue, assignedJobs: snapshot.assignedJobs))
      await tick()
    case let .providerDegraded(profile, reason):
      note(.providerDegraded(profile: profile.rawValue, reason: reason))
    case let .jobStarted(profile, runnerName, requestId):
      logger.info(
        "job started",
        metadata: .context(
          profile: profile, githubJobRequestID: "\(requestId)", host: hostId,
          githubRunnerName: runnerName))
    // Recorded only. Spec §51: `JobCompleted` never drives teardown — the runner's own exit,
    // observed through `agent.runnerStatus`, is the authority on when a session is over.
    case let .jobCompleted(profile, runnerName, requestId, result):
      logger.info(
        "job completed",
        metadata: .context(
          profile: profile, githubJobRequestID: "\(requestId)", host: hostId,
          githubRunnerName: runnerName
        ).merging(["result": .string(result ?? "-")]) { $1 })
    }
  }

  func note(_ event: OrchestratorEvent) {
    events.append(OrchestratorEventRecord(at: now(), event: event))
    if events.count > tuning.eventRingSize {
      events.removeFirst(events.count - tuning.eventRingSize)
    }
    logger.info(
      "orchestrator event",
      metadata: .context(host: hostId).merging([
        "event": .string(event.name), "profile": .string(event.profile),
        "detail": .string(event.detail),
      ]) { $1 })
    // `OrchestratorEvent.profile` is whatever the emitting site had in hand — a profile name for
    // the tick, a profile id for the demand stream — so it goes out under `profile_id` verbatim
    // rather than being guessed at. Handed to a detached task because `note` is synchronous at
    // every call site; the file's `ts` is what orders these, not the order they are appended in.
    let log = eventLog
    let fields = LifecycleEventLog.Fields(
      profile: RunnerProfileID(rawValue: event.profile), to: event.name, reason: event.detail)
    Task { await log?.record(event.name, fields) }
  }

  static func describe(_ error: any Error) -> String {
    guard let error = error as? any RunnerError else { return String(describing: error) }
    return "\(error.code): \(error.message)"
  }
}

/// Drives `Orchestrator.tick()` from the daemon's 10-second reconcile loop (spec §105). The
/// orchestrator reports no `ReconcileCounts` of its own: what it did is in its event ring.
public struct OrchestratorReconcileStep: ReconcileStep {
  private let orchestrator: Orchestrator

  public init(orchestrator: Orchestrator) {
    self.orchestrator = orchestrator
  }

  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    await orchestrator.tick()
    return ReconcileCounts()
  }
}

/// Runs several steps in one tick. `Reconciler` holds exactly one step, and M6 adds a second.
public struct CompositeReconcileStep: ReconcileStep {
  private let steps: [any ReconcileStep]

  public init(_ steps: [any ReconcileStep]) {
    self.steps = steps
  }

  /// Every step runs even when an earlier one threw: a failing orchestrator pass must not stop
  /// worker recovery, and vice versa. The first failure is reported once they all have.
  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    var counts = ReconcileCounts()
    var failure: (any Error)?
    for step in steps {
      do {
        let result = try await step.run(firstTick: firstTick)
        counts.instances += result.instances
        counts.workersConnected += result.workersConnected
        counts.interrupted += result.interrupted
        counts.orphans += result.orphans
        counts.swept += result.swept
        counts.sessionsTerminalized += result.sessionsTerminalized
      } catch {
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
    return counts
  }
}
