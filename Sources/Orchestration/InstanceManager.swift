import Foundation
import GuestControl
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging
import WorkerProtocol

/// What `InstanceManager.delete(id:expectedState:)` did.
///
/// `skipped` is not an error: it says the row moved between the caller's judgement and the commit,
/// so whoever moved it owns the teardown now. The state carried is the one that won.
public enum InstanceDeleteOutcome: Sendable, Equatable {
  case deleted(InstanceRecord)
  case skipped(state: InstanceState)
}

/// Drives one VM through `planned → … → waitingForAgent` and back down again.
///
/// Every state change goes through `InstanceRepository.transition`, which is a compare-and-swap on
/// the persisted state: an event arriving while `create` is still walking the ladder can never
/// skip or duplicate an edge. `waitingForAgent` is the resting state in M2 — `idle` requires the
/// guest agent handshake and is not invented here.
public actor InstanceManager {
  public struct Tuning: Sendable {
    /// Fallback for `timeouts.gracefulShutdown`, used only when the instance's profile row is
    /// gone (a VM outlives a profile the operator removed). The live value comes from the
    /// profile — see `gracefulShutdownMs(for:)`.
    public var gracefulShutdownMs: Int64 = 30_000
    public var workerExitPollInterval: Duration = .milliseconds(200)
    /// Floor for the exit wait. The real budget is derived from the profile's grace window
    /// (`Self.workerExitAttempts`): vmworker forces the guest down only once that window closes,
    /// and a runnerd that gives up first wedges the row in `deleting`.
    public var workerExitPollAttempts: Int = 200
    /// How often a boot watcher re-reads a row parked in `startingVM`. The deadline it enforces is
    /// the profile's `timeouts.vmBoot`; only the spacing of the reads is tuned here.
    public var vmRunningPollInterval: Duration = .milliseconds(200)
    /// Backoff schedule for the `waitingForAgent` poll. The deadline itself comes from the
    /// profile's `timeouts.agentReady`.
    public var agentReadiness = GuestAgentClient.ReadinessPolicy()
    /// Injected so the `reuse.maxAge` check is testable without waiting out a real interval.
    public var now: @Sendable () -> Date = { Date() }

    public init() {}
  }

  /// States a running VM can be interrupted from. `stopping`, `deleting` and the terminal states
  /// are excluded: an intentional teardown must not be reported as an interruption.
  static let interruptibleStates: Set<InstanceState> = [
    .startingWorker, .startingVM, .waitingForAgent, .idle, .configuringRunner, .runnerStarting,
    .runnerOnline, .busy, .cleaning,
  ]

  // Not `private`: `InstanceCreation.swift` extends this actor from a separate file to keep this
  // one under the 500-line budget, and cross-file extensions cannot see `private` members.
  let paths: RunnerPaths
  let hostId: HostID
  let instances: any InstanceRepository
  let profiles: any ProfileRepository
  let imageRows: any ImageRepository
  let images: ImageManager
  let imageStore: ImageStore
  let instanceStore: InstanceStore
  let supervisor: WorkerSupervisor
  let probe: HostProbeResult
  /// The daemon-wide admission lock. `create` takes the capacity snapshot, admits against it and
  /// inserts the `planned` row inside it, so the row the next snapshot must see already exists
  /// before another caller can be admitted (spec §121).
  let admissionQueue: AdmissionQueue
  let metrics: MetricRegistry
  /// Grades an image's baked-in `actions/runner` against the newest release (spec §53). `nil` in
  /// wiring that has no GitHub side at all, which admits every image unconditionally.
  let runnerVersions: RunnerVersionMonitor?
  let tuning: Tuning
  let logger: Logger

  // Not `private`: `InstanceRunnerControl.swift` extends this actor from a separate file.
  let guests: GuestSessions
  var configuration: RunnerConfiguration?
  /// One readiness poll per instance in `waitingForAgent`; cancelled by stop, delete or interrupt.
  /// Not `private`: `InstanceGuestAgent.swift` extends this actor from a separate file.
  var readiness: [InstanceID: Task<Void, Never>] = [:]
  /// One boot watcher per instance in `startingVM`, bounding the profile's `timeouts.vmBoot`
  /// (`InstanceCreation.watchBoot`). `instance.create` returns as soon as `vm.start` is
  /// acknowledged, so this is what is left watching the guest's own boot. Not `private`:
  /// `InstanceCreation.swift` extends this actor from a separate file.
  var bootWatchers: [InstanceID: Task<Void, Never>] = [:]
  /// Ids runnerd is deliberately tearing down; worker events for these are expected, not failures.
  var teardown: Set<InstanceID> = []
  /// Ids a reusable restart is walking back up (`InstanceTaint.respawn`), by how many respawns
  /// hold them. Held for the whole respawn, including the window before its
  /// `interrupted -> startingWorker` CAS lands, so the retention sweep cannot delete the row out
  /// from under a restart that has already been decided.
  ///
  /// Counted rather than a set because a worker death arrives twice — once as a lost connection,
  /// once from the reconciler — so two respawns race for one row and only one wins the CAS. With a
  /// set, the loser's exit would release the winner's claim. Not `private`: `InstanceTaint.swift`
  /// extends this actor from a separate file.
  var restarting: [InstanceID: Int] = [:]
  /// Digests already reported as past GitHub's runner update window, so a profile that keeps
  /// starting VMs from a stale image logs once rather than once per boot. Not `private`:
  /// `InstanceCreation.swift` extends this actor from a separate file.
  var warnedRunnerTooOld: Set<ImageDigest> = []
  /// When vmworker reported the VM running. Not persisted: it only exists to split the boot
  /// ladder's two halves apart for spec §41, and a restart legitimately loses the split.
  var vmRunningAt: [InstanceID: ContinuousClock.Instant] = [:]
  /// `logs/events.jsonl`. Attached after construction rather than injected, so every existing
  /// wiring keeps compiling and a daemon that cannot open the file simply has none. Not
  /// `private`: `InstanceReuse`/`InstanceDiagnostics` extend this actor from separate files.
  var events: LifecycleEventLog?
  /// Test seam: runs inside `failBootTimeout`, after it has read the row and before the write that
  /// would fail it, so a test can land the exact interleaving that compare-and-swap exists to lose.
  /// Never set outside `OrchestrationTests`; the production cost is one nil check per timeout.
  var afterBootTimeoutRead: (@Sendable () async -> Void)?
  /// Capacity held by in-flight image builds. `nil` until Phase 5 attaches a builder; admission
  /// then charges the host for builds and instances out of the same budget. Not `private`:
  /// `InstanceCreation.swift` extends this actor from a separate file.
  var imageBuilds: (any ImageBuildReservationSource)?

  public init(
    paths: RunnerPaths, hostId: HostID, instances: any InstanceRepository,
    profiles: any ProfileRepository, imageRows: any ImageRepository, images: ImageManager,
    imageStore: ImageStore, instanceStore: InstanceStore, supervisor: WorkerSupervisor,
    probe: HostProbeResult, admissionQueue: AdmissionQueue = AdmissionQueue(),
    metrics: MetricRegistry = MetricRegistry(),
    runnerVersions: RunnerVersionMonitor? = nil, tuning: Tuning = Tuning(),
    logger: Logger = Logger(component: .daemon)
  ) {
    self.paths = paths
    self.hostId = hostId
    self.instances = instances
    self.profiles = profiles
    self.imageRows = imageRows
    self.images = images
    self.imageStore = imageStore
    self.instanceStore = instanceStore
    self.supervisor = supervisor
    self.probe = probe
    self.admissionQueue = admissionQueue
    self.metrics = metrics
    self.runnerVersions = runnerVersions
    self.tuning = tuning
    self.logger = logger
    self.guests = GuestSessions(paths: paths)
  }

  public func updateConfiguration(_ config: RunnerConfiguration?) {
    configuration = config
  }

  public func attachEventLog(_ log: LifecycleEventLog?) {
    events = log
  }

  /// Phase 5 seam: the builder registers here so its running builds are charged against the same
  /// host budget instance admission uses.
  public func attachImageBuilds(_ source: (any ImageBuildReservationSource)?) {
    imageBuilds = source
  }

  /// `logging.collectRunnerDiagnostics` / `logging.diagnosticsTimeout`, resolved at the point of
  /// use so a `config.apply` takes effect on the next session rather than the next restart.
  func loggingConfiguration() -> LoggingConfig {
    configuration?.logging ?? LoggingConfig()
  }

  /// The host-side metric registry (spec §40, §41). `RunnerSessionManager` records its own
  /// lifecycle timings into this same registry: it reaches it through the instance manager it
  /// already depends on rather than carrying a second injection point of its own.
  public func metricRegistry() -> MetricRegistry { metrics }

  func profileName(_ id: RunnerProfileID) async -> String {
    guard let rows = try? await profiles.list(),
          let row = rows.first(where: { $0.id == id })
    else { return id.rawValue }
    return row.name
  }

  /// The SIGTERM-to-SIGKILL window this instance's profile asks for (`timeouts.gracefulShutdown`),
  /// in milliseconds. Falls back to `tuning.gracefulShutdownMs` when the profile row or its config
  /// cannot be read — a VM outlives a profile the operator deleted, and its teardown still has to
  /// pick a number. Same lookup shape as `InstanceGuestAgent.agentReadyTimeout`.
  func gracefulShutdownMs(for record: InstanceRecord) async -> Int64 {
    guard let rows = try? await profiles.list(),
          let row = rows.first(where: { $0.id == record.profileId }),
          let config = try? row.decodedConfig()
    else { return tuning.gracefulShutdownMs }
    return config.effectiveTimeouts.gracefulShutdown.milliseconds
  }

  /// `gracefulShutdownMs(for:)` for a caller that holds an id rather than a row.
  func gracefulShutdownMs(for id: InstanceID) async -> Int64 {
    guard let record = try? await require(id) else { return tuning.gracefulShutdownMs }
    return await gracefulShutdownMs(for: record)
  }

  public func failedInstanceRetention() -> Duration {
    (configuration?.diagnostics ?? DiagnosticsConfig()).failedInstanceRetention.duration
  }

  // MARK: - Queries

  public func list() async throws -> [InstanceRecord] {
    try await instances.list(profile: nil, states: nil).sorted { $0.createdAt.date < $1.createdAt.date }
  }

  public func get(id: InstanceID) async throws -> InstanceRecord { try await require(id) }

  public func runningCount() async throws -> Int {
    try await instances.list(profile: nil, states: nil).count { $0.state.hasRunningVM }
  }

  /// True while `stop`, `delete` or `interrupt` is walking this row down. The reconciler's sweeps
  /// use it to stay off rows that already have an owner: a second teardown would race the first
  /// into `waitForWorkerExit` and report a failure for a delete that is going fine.
  public func isTearingDown(_ id: InstanceID) -> Bool { teardown.contains(id) }

  /// True while `restartInterrupted` is respawning this row's worker (spec §72). Same contract as
  /// `isTearingDown`: the restart owns the row until it either boots or gives up and deletes.
  public func isRestarting(_ id: InstanceID) -> Bool { restarting[id] != nil }

  /// Claims `id` for one respawn. Paired with `endRestart`; see `restarting` for why it counts.
  func beginRestart(_ id: InstanceID) {
    restarting[id, default: 0] += 1
  }

  func endRestart(_ id: InstanceID) {
    guard let held = restarting[id] else { return }
    restarting[id] = held > 1 ? held - 1 : nil
  }

  /// Ends the boot watch on `id`. A watcher retires itself the moment the row leaves `startingVM`,
  /// but a teardown must not leave one polling for as long as its poll interval: whoever takes the
  /// row down owns it from here, and nothing else may report a boot timeout against it.
  func cancelBootWatch(_ id: InstanceID) {
    bootWatchers.removeValue(forKey: id)?.cancel()
  }

  // MARK: - Create
  //
  // `create(profileName:)` and its helpers (`plan`, `makeRecord`, `bringUp`, `stage`, `spawn`,
  // `boot`) live in `InstanceCreation.swift`, an extension of this actor, to keep this file under
  // the line budget. `require`, `transition` and `fail` below are `internal` rather than
  // `private` so that extension can call them.

  // MARK: - Stop / delete

  public func stop(id: InstanceID, force: Bool) async throws -> InstanceRecord {
    let record = try await require(id)
    if record.state == .stopped { return record }
    guard record.state.allowedTransitions.contains(.stopping) else {
      throw OrchestrationError.instanceNotStoppable(id: id.rawValue, state: record.state.rawValue)
    }
    let graceMs = await gracefulShutdownMs(for: record)
    teardown.insert(id)
    defer { teardown.remove(id) }
    await releaseGuest(id)
    let stopping = try await transition(record, to: .stopping)
    if force { _ = try? await supervisor.forceStop(id: id) }
    try? await supervisor.shutdown(id: id, reason: .stop, gracefulTimeoutMs: graceMs)
    _ = await waitForWorkerExit(id: id, graceMs: graceMs)
    return try await transition(stopping, to: .stopped) { record in
      record.stoppedAt = .now
      record.workerPid = nil
      record.workerSocket = nil
    }
  }

  /// Stops first when the state machine has no direct edge to `deleting` (a booted VM must be shut
  /// down before its directory can go).
  ///
  /// Resumable from `deleting`: a teardown that lost the race with a slow guest must be
  /// retryable, otherwise the row is stranded in a state whose only exit is `deleted`.
  public func delete(id: InstanceID) async throws -> InstanceRecord {
    let startedAt = ContinuousClock.now
    var record = try await require(id)
    if record.state == .deleted { return record }
    if record.state != .deleting, !record.state.allowedTransitions.contains(.deleting) {
      guard record.state.allowedTransitions.contains(.stopping) else {
        throw OrchestrationError.instanceNotDeletable(id: id.rawValue, state: record.state.rawValue)
      }
      record = try await stop(id: id, force: true)
    }
    teardown.insert(id)
    defer { teardown.remove(id) }
    await releaseGuest(id)
    let deleting = record.state == .deleting ? record : try await transition(record, to: .deleting)
    return try await tearDown(deleting, startedAt: startedAt)
  }

  /// Deletes only while the row is still in the state the caller judged it on.
  ///
  /// A sweep lists rows, then decides, then commits — and every step in between is an `await` the
  /// row can move under. Committing from `expectedState` makes the whole decision atomic with the
  /// CAS: anything that moved the row first (a respawn claiming `startingWorker`, an operator's
  /// own `delete`) wins, and this returns `skipped` rather than tearing down a live VM.
  public func delete(
    id: InstanceID, expectedState: InstanceState
  ) async throws -> InstanceDeleteOutcome {
    let startedAt = ContinuousClock.now
    let fresh = try await require(id)
    guard fresh.state == expectedState, fresh.state.allowedTransitions.contains(.deleting),
          !teardown.contains(id), !isRestarting(id)
    else { return .skipped(state: fresh.state) }
    teardown.insert(id)
    defer { teardown.remove(id) }
    // The read above is a suspension point and the row can move under it. What closes that window
    // is not the ordering here but `InstanceRepository.transition` itself: it re-reads and writes
    // inside one write transaction and refuses unless the persisted state is still `fresh.state`.
    // So a row somebody else moved fails this CAS instead of being torn down on a stale reading.
    let deleting: InstanceRecord
    do {
      deleting = try await transition(fresh, to: .deleting)
    } catch {
      // A lost CAS is the ordinary outcome of a race and needs no operator attention. Anything
      // else is a database fault the caller is about to swallow as `skipped`, so say it once here.
      if !Self.isStaleWrite(error) {
        logger.warning(
          "a state-checked delete could not commit",
          metadata: .context(instance: id).merging([
            "expected": .string(expectedState.rawValue),
            "error": .string(String(describing: error)),
          ]) { $1 })
      }
      return .skipped(state: (try? await require(id))?.state ?? expectedState)
    }
    await releaseGuest(id)
    return .deleted(try await tearDown(deleting, startedAt: startedAt))
  }

  /// A CAS this caller lost, as opposed to a database fault.
  private static func isStaleWrite(_ error: any Error) -> Bool {
    guard let error = error as? PersistenceError, case .staleWrite = error else { return false }
    return true
  }

  /// Everything past the row reading `deleting`: stop the worker, preserve the diagnostics, unpin
  /// the image and unlink the directory. Shared by both `delete` entry points, which differ only
  /// in how they are allowed to reach `deleting`.
  ///
  /// The caller owns the `teardown` bracket, because the guest has to be released inside it too.
  private func tearDown(
    _ deleting: InstanceRecord, startedAt: ContinuousClock.Instant
  ) async throws -> InstanceRecord {
    let id = deleting.id
    let graceMs = await gracefulShutdownMs(for: deleting)
    if await supervisor.liveness(id: id) == .connected {
      try? await supervisor.shutdown(id: id, reason: .stop, gracefulTimeoutMs: graceMs)
    }
    guard await waitForWorkerExit(id: id, graceMs: graceMs) else {
      throw VMError.workerLockHeldByOtherProcess(
        path: paths.instanceDir(id).appending(path: VMInstanceLayout.workerLockName)
          .path(percentEncoded: false))
    }
    await supervisor.forget(id: id)
    removeSockets(id)
    // The instance directory is about to go; its serial console, worker output and failure record
    // are the only evidence of what this VM did, so they move to `logs/instances/<id>/` first.
    preserveInstanceLogs(id)
    try await instanceStore.delete(instanceId: id)
    try await imageRows.unpin(
      ownerType: .instance, ownerId: id.rawValue, digest: deleting.imageDigest)
    let deleted = try await transition(deleting, to: .deleted) { record in
      record.deletedAt = .now
      record.workerPid = nil
      record.workerSocket = nil
    }
    await metrics.observe(
      RunnerVMMetrics.instanceDeleteSeconds,
      labels: [RunnerVMMetrics.profileLabel: await profileName(deleted.profileId)],
      since: startedAt)
    vmRunningAt[id] = nil
    return deleted
  }

  /// A worker that exits cleanly unlinks its own sockets, but one that dies during startup does
  /// not; without this the socket directory accumulates dead entries.
  private func removeSockets(_ id: InstanceID) {
    for socket in [paths.workerSocket(id), paths.agentSocket(id)] {
      try? FileManager.default.removeItem(at: socket)
    }
  }

  /// Never signals a pid: the only proof a worker is gone is that its `fcntl` lock is released.
  ///
  /// The budget scales with `graceMs` because vmworker only forces the guest down once its own
  /// grace window closes; a wait that expired first would leave the row wedged in `deleting`.
  func waitForWorkerExit(id: InstanceID, graceMs: Int64) async -> Bool {
    for _ in 0..<Self.workerExitAttempts(
      graceMs: graceMs, interval: tuning.workerExitPollInterval,
      floor: tuning.workerExitPollAttempts) {
      if await supervisor.liveness(id: id) == .dead { return true }
      try? await Task.sleep(for: tuning.workerExitPollInterval)
    }
    return await supervisor.liveness(id: id) == .dead
  }

  /// `graceMs` plus the 15 s vmworker needs to force the guest down and unlink afterwards, in
  /// polls — never fewer than the configured floor, and never more than `exitWaitCeiling`: an
  /// operator who sets a grace of hours must not have runnerd sit in `deleting` for hours too.
  static func workerExitAttempts(graceMs: Int64, interval: Duration, floor: Int) -> Int {
    let pollMs = max(1, DurationValue(interval).milliseconds)
    let scaled = (max(0, graceMs) + 15_000) / pollMs
    let ceiling = max(1, exitWaitCeilingMs / pollMs)
    return Int(min(max(Int64(floor), scaled), ceiling))
  }

  static let exitWaitCeilingMs: Int64 = 120_000

  // MARK: - Worker events

  public func handleWorkerState(id: InstanceID, vmState: WorkerVMState) async {
    await applyVMState(id, vmState)
  }

  public func handleWorkerDisconnect(id: InstanceID) async {
    guard !teardown.contains(id) else { return }
    let previous = try? await require(id)
    await interrupt(id, code: "VM_WORKER_UNRESPONSIVE", message: "worker connection lost")
    if let previous { await restartInterrupted(previous) }
  }

  /// Reconciliation found no lock and no socket: the worker is gone for good. Spec §72 lets an
  /// idle reusable VM come back from this; the pre-interrupt row is what decides.
  public func markWorkerDead(id: InstanceID) async {
    guard !teardown.contains(id) else { return }
    let previous = try? await require(id)
    await interrupt(id, code: "VM_WORKER_UNRESPONSIVE", message: "worker process is gone")
    if let previous { await restartInterrupted(previous) }
  }

  /// `adopted` marks a state read off a re-adopted worker at startup rather than observed as it
  /// happened: the row still has to catch up, but the boot timings must not, because the interval
  /// they would measure spans however long the daemon was down.
  func applyVMState(_ id: InstanceID, _ vmState: WorkerVMState, adopted: Bool = false) async {
    guard !teardown.contains(id), let record = try? await require(id) else { return }
    switch vmState {
    case .running:
      guard record.state == .startingVM else { return }
      let landed = (try? await transition(record, to: .waitingForAgent) { record in
        record.startedAt = record.startedAt ?? .now
      }) != nil
      // Only once the row has really left `startingVM`: a transition that did not land leaves the
      // boot exactly where it was, and the watcher is still the only thing bounding it.
      if landed { cancelBootWatch(id) }
      if !adopted { await observeBoot(record) }
      startReadiness(id)
    case .stopped, .error:
      await interrupt(
        id, code: "VM_STOPPED_UNEXPECTEDLY", message: "worker reported vmState \(vmState.rawValue)")
    case .starting, .stopping:
      break
    }
  }

  func interrupt(
    _ id: InstanceID, code: String, message: String, taint: String? = nil
  ) async {
    guard let record = try? await require(id),
          Self.interruptibleStates.contains(record.state) else { return }
    // Same bracket `stop` and `delete` take: the worker events this teardown provokes are expected,
    // and handling them as failures would interrupt the instance a second time.
    teardown.insert(id)
    defer { teardown.remove(id) }
    // Row first, guest second. The actor is reentrant at every `await`, so a runner-session
    // observer polling `agent.runnerStatus` in between would otherwise see a half-closed guest
    // client under a row that still says `busy` and report the loss as an agent failure rather
    // than as the VM going away (`VM_LOST`). Once the row reads `interrupted`, every later poll
    // takes the instance-state path deterministically.
    _ = try? await transition(record, to: .interrupted) { record in
      record.stoppedAt = .now
      record.failureCode = code
      record.failureMessage = message
      if let taint {
        record.tainted = true
        record.taintReason = taint
      }
    }
    await releaseGuest(id)
    logger.warning(
      "instance interrupted",
      metadata: .context(profile: record.profileId, instance: id, host: hostId)
        .merging(["reason": .string(message), "code": .string(code)]) { $1 })
  }

  // MARK: - Internals

  func require(_ id: InstanceID) async throws -> InstanceRecord {
    guard let record = try await instances.get(id: id) else {
      throw OrchestrationError.instanceUnknown(id: id.rawValue)
    }
    return record
  }

  /// The compare-and-swap every state change goes through: `record.state` is the `from` side, so
  /// the row is written only while it still reads what the caller judged it on. `expectedGeneration`
  /// fences the *boot* as well as the state, for callers that must not act on a row a restart has
  /// already claimed again.
  @discardableResult
  func transition(
    _ record: InstanceRecord, to state: InstanceState, expectedGeneration: Int? = nil,
    mutate: @escaping @Sendable (inout InstanceRecord) -> Void = { _ in }
  ) async throws -> InstanceRecord {
    let updated = try await instances.transition(
      id: record.id, from: record.state, to: state, expectedGeneration: expectedGeneration,
      mutate: mutate)
    logger.info(
      "instance transition",
      metadata: .context(
        profile: record.profileId, instance: record.id, imageDigest: record.imageDigest,
        host: hostId
      ).merging([
        "from": .string(record.state.rawValue), "to": .string(state.rawValue),
      ]) { $1 })
    await events?.record(
      LifecycleEventLog.instanceTransition,
      LifecycleEventLog.Fields(
        instance: record.id, profile: record.profileId, from: record.state.rawValue,
        to: state.rawValue, reason: updated.failureCode))
    return updated
  }

  /// Ends the instance in `failed` and reports it -- but only if this call is the one that got it
  /// there. Everything the operator would read as evidence (`failure.json`, the failure metric, the
  /// log line) hangs off the compare-and-swap, because a row somebody else moved first -- a
  /// `running` event that beat a boot deadline by microseconds, a delete already walking it down --
  /// never had the failure this would otherwise describe.
  /// `expecting`/`generation` are for a caller that has already read the row and needs *that*
  /// reading to be what commits: the expectation goes straight into the compare-and-swap instead of
  /// being re-read here, because the re-read is itself a suspension point a `running` event can land
  /// in -- and `waitingForAgent -> failed` is a legal edge, so it would commit against a healthy
  /// guest. Callers without one hold a record from before their own transition, so the row is read.
  /// `workerPID` names the worker that was up when this failed, for the phases whose row does not
  /// carry the pid yet.
  @discardableResult
  func fail(
    _ record: InstanceRecord, phase: String, error: any Error,
    expecting: InstanceState? = nil, generation: Int? = nil, workerPID: Int32? = nil
  ) async -> Bool {
    let runnerError = error as? any RunnerError
    let code = runnerError?.code ?? "INTERNAL"
    let message = runnerError?.message ?? String(describing: error)
    let target: InstanceRecord
    if let expecting {
      guard record.state == expecting else { return false }
      target = record
    } else {
      guard let fresh = try? await require(record.id) else { return false }
      target = fresh
    }
    guard target.state.allowedTransitions.contains(.failed) else { return false }
    guard (try? await transition(target, to: .failed, expectedGeneration: generation, mutate: { record in
      // Stamped exactly as `interrupt` does: the retention window the reconciler reaps against is
      // measured from when the instance stopped, and without this a row that failed minutes into
      // its boot would be judged on `createdAt` and swept early.
      record.stoppedAt = .now
      record.failureCode = code
      record.failureMessage = message
    })) != nil else { return false }
    try? await instanceStore.recordFailure(
      instanceId: record.id,
      FailureRecord(
        instanceId: record.id, code: code, message: message, phase: phase,
        retryable: runnerError?.retryable ?? false, occurredAt: Date(),
        workerPID: workerPID ?? target.workerPid))
    await metrics.increment(
      RunnerVMMetrics.instanceFailuresTotal,
      labels: [
        RunnerVMMetrics.profileLabel: await profileName(record.profileId),
        RunnerVMMetrics.codeLabel: code,
      ])
    logger.error(
      "instance failed",
      metadata: .context(profile: record.profileId, instance: record.id, host: hostId).merging([
        "phase": .string(phase), "code": .string(code), "error": .string(message),
      ]) { $1 })
    return true
  }

  /// `startedAt` is stamped when the worker session is up, so this is the guest's own boot time
  /// rather than the whole create ladder (spec §41).
  private func observeBoot(_ record: InstanceRecord) async {
    vmRunningAt[record.id] = ContinuousClock.now
    guard let started = record.startedAt?.date else { return }
    await metrics.observe(
      RunnerVMMetrics.vmBootToRunningSeconds,
      labels: [RunnerVMMetrics.profileLabel: await profileName(record.profileId)],
      seconds: max(0, Date().timeIntervalSince(started)))
  }
}
