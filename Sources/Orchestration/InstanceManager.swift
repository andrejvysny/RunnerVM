import Foundation
import GuestControl
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging
import WorkerProtocol

/// Drives one VM through `planned → … → waitingForAgent` and back down again.
///
/// Every state change goes through `InstanceRepository.transition`, which is a compare-and-swap on
/// the persisted state: an event arriving while `create` is still walking the ladder can never
/// skip or duplicate an edge. `waitingForAgent` is the resting state in M2 — `idle` requires the
/// guest agent handshake and is not invented here.
public actor InstanceManager {
  public struct Tuning: Sendable {
    public var gracefulShutdownMs: Int64 = 30_000
    public var workerExitPollInterval: Duration = .milliseconds(200)
    /// Must outlast `gracefulShutdownMs`: vmworker forces the guest down only once that window
    /// closes, and a runnerd that gives up first wedges the row in `deleting`.
    public var workerExitPollAttempts: Int = 200
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
  /// Ids runnerd is deliberately tearing down; worker events for these are expected, not failures.
  var teardown: Set<InstanceID> = []
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
    teardown.insert(id)
    defer { teardown.remove(id) }
    await releaseGuest(id)
    let stopping = try await transition(record, to: .stopping)
    if force { _ = try? await supervisor.forceStop(id: id) }
    try? await supervisor.shutdown(
      id: id, reason: .stop, gracefulTimeoutMs: tuning.gracefulShutdownMs)
    _ = await waitForWorkerExit(id: id)
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
    if await supervisor.liveness(id: id) == .connected {
      try? await supervisor.shutdown(
        id: id, reason: .stop, gracefulTimeoutMs: tuning.gracefulShutdownMs)
    }
    guard await waitForWorkerExit(id: id) else {
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
  private func waitForWorkerExit(id: InstanceID) async -> Bool {
    for _ in 0..<tuning.workerExitPollAttempts {
      if await supervisor.liveness(id: id) == .dead { return true }
      try? await Task.sleep(for: tuning.workerExitPollInterval)
    }
    return await supervisor.liveness(id: id) == .dead
  }

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

  func applyVMState(_ id: InstanceID, _ vmState: WorkerVMState) async {
    guard !teardown.contains(id), let record = try? await require(id) else { return }
    switch vmState {
    case .running:
      guard record.state == .startingVM else { return }
      _ = try? await transition(record, to: .waitingForAgent) { record in
        record.startedAt = record.startedAt ?? .now
      }
      await observeBoot(record)
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
    await releaseGuest(id)
    _ = try? await transition(record, to: .interrupted) { record in
      record.stoppedAt = .now
      record.failureCode = code
      record.failureMessage = message
      if let taint {
        record.tainted = true
        record.taintReason = taint
      }
    }
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

  @discardableResult
  func transition(
    _ record: InstanceRecord, to state: InstanceState,
    mutate: @escaping @Sendable (inout InstanceRecord) -> Void = { _ in }
  ) async throws -> InstanceRecord {
    let updated = try await instances.transition(
      id: record.id, from: record.state, to: state, expectedGeneration: nil, mutate: mutate)
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

  func fail(_ record: InstanceRecord, phase: String, error: any Error) async {
    let runnerError = error as? any RunnerError
    let code = runnerError?.code ?? "INTERNAL"
    let message = runnerError?.message ?? String(describing: error)
    try? await instanceStore.recordFailure(
      instanceId: record.id,
      FailureRecord(
        instanceId: record.id, code: code, message: message, phase: phase,
        retryable: runnerError?.retryable ?? false, occurredAt: Date(),
        workerPID: record.workerPid))
    guard let fresh = try? await require(record.id),
          fresh.state.allowedTransitions.contains(.failed) else { return }
    _ = try? await transition(fresh, to: .failed) { record in
      record.failureCode = code
      record.failureMessage = message
    }
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
