import DaemonAPI
import Foundation
import GitHubControl
import GuestControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging
import Synchronization

/// Drives one GitHub runner session over an already-booted, idle VM (spec §47, §48 steps 14-23).
///
/// The order is the whole point: the `runner_sessions` row exists *before* the JIT config is
/// requested, so a daemon that dies between the POST and the reply still has a row to reconcile
/// the orphaned runner from. The JIT config itself lives only in a local `let` between
/// `generate-jitconfig` and `agent.startRunner`; it is never persisted, never logged, and never
/// returned to a caller (spec §36, §128).
public actor RunnerSessionManager {
  public struct Tuning: Sendable {
    /// Cadence of `agent.runnerStatus`. Injected so tests drive the state machine without waiting.
    public var pollInterval: Duration = .seconds(2)
    /// Consecutive unreadable `agent.runnerStatus` answers before the runner counts as lost.
    public var lostPollThreshold: Int = 3

    public init() {}
  }

  /// Where the JIT registration comes from (spec §36 vs §50). `scaleSet` binds the runner to the
  /// scale set instead of to a job, which is what lets GitHub route work to it.
  public enum JITOrigin: Sendable, Equatable {
    case rest
    case scaleSet(id: Int64)

    var source: JitSource {
      switch self {
      case .rest: .rest
      case .scaleSet: .scaleSet
      }
    }
  }

  /// GitHub's own default; the images lay the runner out to match.
  static let defaultWorkFolder = "_work"

  /// Everything one session needs, resolved once so the observer never re-reads configuration
  /// mid-flight and changes its mind about scope or lifecycle.
  ///
  /// Recovery after a restart builds one of these for a session whose profile or scope row may
  /// have been removed from the configuration since, so everything the session did not strictly
  /// need to *start* is optional here.
  struct SessionContext: Sendable {
    let profile: RunnerProfileConfig
    let scopeRecord: GitHubScopeRecord?
    let scope: GitHubScope
    /// `nil` when no GitHub credential is configured. Only `issueJIT` requires it; a removal
    /// resolves its own plane through the gateway so an outage becomes a retryable operation row.
    let plane: (any GitHubActionsControlPlane)?
    let origin: JITOrigin
    let scaleSetPlane: (any ScaleSetControlPlane)?
  }

  /// VM states in which a session is still meaningfully running.
  static let liveInstanceStates: Set<InstanceState> = [
    .configuringRunner, .runnerStarting, .runnerOnline, .busy,
  ]

  let sessions: any RunnerSessionRepository
  let instanceRows: any InstanceRepository
  let profiles: any ProfileRepository
  let scopes: any ScopeRepository
  let summaries: any JobSummaryRepository
  let operations: any OperationRepository
  let instances: InstanceManager
  let gateway: GitHubGateway
  let tuning: Tuning
  let logger: Logger
  var observers: [RunnerSessionID: Task<Void, Never>] = [:]
  /// Sessions whose `register` is still in flight, and when each mark was last stamped.
  ///
  /// The stretch between `insertRow` and the first `observe` is a persisted, non-terminal row with
  /// no observer -- exactly the shape `recoverSessions` terminalizes -- and every `await` inside it
  /// suspends this reentrant actor, so a reconcile tick runs *inside* the registration. This map is
  /// that window's owner, and it covers the whole of `register`, not just the JIT call: the mark is
  /// re-stamped when `issueJIT` returns, so the grace bounds one stage rather than the sum of them.
  ///
  /// Monotonic on purpose. A wall clock steps forward under NTP, and an in-memory claim that
  /// expired on a clock correction would hand a live registration to the next sweep.
  ///
  /// Deliberately not a placeholder in `observers`: the success path installs the real observer
  /// under the same key, so clearing a placeholder on the way out would clobber it, and both
  /// `detachObservers` and `observedSessions()` would see entries watching nothing.
  var registering: [RunnerSessionID: ContinuousClock.Instant] = [:]
  /// Runner ids that must ride along on a session's next state write, by session.
  ///
  /// `finish` closes a session through a compare-and-swap whose `mutate` it owns, and a terminal
  /// `runner_sessions` state has no outgoing edge, so a caller can neither add a column to that
  /// write nor add one afterwards. The JIT-deadline path discovers a runner id at exactly that
  /// moment -- the registration GitHub made while the caller was giving up -- and
  /// `retryPendingRemovals` re-drives a failed DELETE from `githubRunnerId` and nothing else, so
  /// the id has to travel on the closing CAS or be lost. `move` merges it in; the writer clears the
  /// entry as soon as its `finish` returns, so nothing lingers.
  var pendingRunnerID: [RunnerSessionID: Int64] = [:]
  /// `logs/events.jsonl`. Attached after construction; see `InstanceManager.attachEventLog`.
  var events: LifecycleEventLog?

  public init(
    sessions: any RunnerSessionRepository, instanceRows: any InstanceRepository,
    profiles: any ProfileRepository, scopes: any ScopeRepository,
    summaries: any JobSummaryRepository, operations: any OperationRepository,
    instances: InstanceManager, gateway: GitHubGateway, tuning: Tuning = Tuning(),
    logger: Logger = Logger(component: .runner)
  ) {
    self.sessions = sessions
    self.instanceRows = instanceRows
    self.profiles = profiles
    self.scopes = scopes
    self.summaries = summaries
    self.operations = operations
    self.instances = instances
    self.gateway = gateway
    self.tuning = tuning
    self.logger = logger
  }

  public func attachEventLog(_ log: LifecycleEventLog?) {
    events = log
  }

  // MARK: - Queries

  public func list(limit: Int? = 200) async throws -> [RunnerSessionRecord] {
    try await sessions.list(limit: limit)
  }

  public func get(id: RunnerSessionID) async throws -> RunnerSessionRecord {
    guard let record = try await sessions.get(id: id) else {
      throw OrchestrationError.runnerSessionUnknown(id: id.rawValue)
    }
    return record
  }

  /// Daemon teardown: stop observing. The runners keep running — they are the guest's business,
  /// and the next start re-reconciles them.
  public func detachObservers() {
    for task in observers.values { task.cancel() }
    observers.removeAll()
  }

  // MARK: - Start

  /// Spec §48 steps 14-17. Returns as soon as the runner has been handed its configuration; the
  /// rest of the lifecycle is watched in the background and observed through `runner.get`.
  @discardableResult
  public func startSession(
    instanceId: InstanceID, origin: JITOrigin = .rest
  ) async throws -> RunnerSessionRecord {
    let context = try await prepare(instanceId, origin: origin)
    let claimed = try await instances.claimForRunnerSession(id: instanceId)
    return try await register(instance: claimed, context: context)
  }

  private func prepare(
    _ instanceId: InstanceID, origin: JITOrigin
  ) async throws -> SessionContext {
    guard let instance = try await instanceRows.get(id: instanceId) else {
      throw OrchestrationError.instanceUnknown(id: instanceId.rawValue)
    }
    guard instance.state == .idle else {
      throw OrchestrationError.instanceNotIdle(
        id: instanceId.rawValue, state: instance.state.rawValue)
    }
    if let active = try await sessions.listActive(instance: instanceId).first {
      throw OrchestrationError.runnerSessionActive(
        instance: instanceId.rawValue, session: active.id.rawValue)
    }
    guard let profileRow = try await profiles.list().first(where: { $0.id == instance.profileId })
    else {
      throw SchedulerError.unknownProfile(name: instance.profileId.rawValue)
    }
    let scopeRecord = try await requireSchedulableScope(profileRow.scopeId)
    guard let plane = await gateway.controlPlane() else {
      throw OrchestrationError.githubNotConfigured(
        reason: "no GitHub credential provider is configured")
    }
    let scaleSetPlane = await gateway.scaleSetControlPlane()
    if case .scaleSet = origin, scaleSetPlane == nil {
      throw OrchestrationError.githubNotConfigured(
        reason: "no scale-set control plane is configured")
    }
    return SessionContext(
      profile: try profileRow.decodedConfig(), scopeRecord: scopeRecord,
      scope: try GitHubMapping.scope(scopeRecord), plane: plane, origin: origin,
      scaleSetPlane: scaleSetPlane)
  }

  /// Fails before any capacity is consumed. `startSession` re-checks — the scope can go bad while
  /// a VM boots — but a caller that is about to create one should not pay for the boot first.
  public func assertSchedulable(profile: RunnerProfileRecord) async throws {
    _ = try await requireSchedulableScope(profile.scopeId)
  }

  /// Spec §134: a scope GitHub no longer answers for stops receiving runners, rather than failing
  /// every job it is handed.
  private func requireSchedulableScope(_ id: GitHubScopeID) async throws -> GitHubScopeRecord {
    guard let record = try await scopes.list().first(where: { $0.id == id }) else {
      throw DaemonServiceError.notFound(entity: "scope", name: id.rawValue)
    }
    guard record.enabled else {
      throw OrchestrationError.scopeNotSchedulable(
        name: record.name, health: "disabled", detail: "the scope is not in the applied document")
    }
    guard record.health == GitHubMapping.healthy else {
      throw OrchestrationError.scopeNotSchedulable(
        name: record.name, health: record.health,
        detail: "run `runnerctl github test` for the problem list")
    }
    return record
  }

  // MARK: - Registration

  /// Slack on top of the profile's `jitGeneration` before a `registering` mark counts as stale.
  /// Two guest `callDeadline`s wide, because the stage after the JIT call spends them back to
  /// back: `deliver`'s `agent.startRunner` and the `startedAnyway` fallback that follows a lost
  /// reply. The row writes and the instance claim fit in the same budget.
  static let registrationSlack = DurationValue.seconds(60)

  /// How long a mark keeps recovery off its row, per stage: `register` re-stamps it on progress.
  /// Bounded on purpose: a `register` that never finished -- a caller parked forever in a GitHub
  /// or guest call -- must not strand its VM, so an older mark is ignored and reaped and the row is
  /// recovered as if it had never been marked.
  static func registrationGrace(_ profile: RunnerProfileConfig) -> DurationValue {
    DurationValue(profile.effectiveTimeouts.jitGeneration.duration + registrationSlack.duration)
  }

  /// Spec §73: `timeouts.jitGeneration` bounds `generate-jitconfig`, on both the REST and the
  /// scale-set path. Without it a GitHub that never answers parks `register` -- and the VM it has
  /// claimed -- until the daemon restarts.
  static func jitDeadline(_ profile: RunnerProfileConfig) -> DurationValue {
    profile.effectiveTimeouts.jitGeneration
  }

  static func jitTimedOut(_ profile: RunnerProfileConfig) -> GitHubControlError {
    .jitGenerationTimeout(seconds: Double(jitDeadline(profile).milliseconds) / 1_000)
  }

  /// Whether a live `register` still owns `id`'s row, `grace` being how long its mark is trusted.
  func isRegistering(_ id: RunnerSessionID, within grace: DurationValue) -> Bool {
    guard let stamped = registering[id] else { return false }
    return stamped.duration(to: .now) < grace.duration
  }

  private func register(
    instance: InstanceRecord, context: SessionContext
  ) async throws -> RunnerSessionRecord {
    // The id is minted here rather than inside `insertRow` so the row can be claimed *before* it
    // becomes visible to `recoverSessions`. The `defer` releases the claim on every exit -- return,
    // throw, cancellation -- and never leaves a gap: `observe` installs the real observer inside
    // `deliverAndStart`, with no suspension point between it and this frame's return, so the actor
    // cannot run a sweep in between.
    let id = RunnerSessionID.generate()
    registering[id] = .now
    defer { registering[id] = nil }
    let planned = try await insertRow(id: id, instance: instance, context: context)
    let requested = try await move(planned, to: .jitRequested)

    let config: JITRunnerConfig
    let issued = IssuedRunnerID()
    do {
      config = try await withDeadline(
        Self.jitDeadline(context.profile), expired: { Self.jitTimedOut(context.profile) }
      ) { [self] in
        let config = try await issueJIT(instance: instance, context: context)
        // Published before the value leaves the body, because the deadline can still win the race
        // the task group is running: past this point the id is the only handle anyone has on the
        // registration. The id only — `encodedJITConfig` is the secret and never leaves the local
        // `let` below (spec §36, §128).
        issued.publish(config.runnerID)
        return config
      }
    } catch {
      await failJIT(requested, issued: issued.current, error: error, context: context)
      throw error
    }
    // Progress re-stamps the claim: `grace` is a per-stage budget, so the guest handoff below gets
    // its own rather than inheriting whatever the JIT call left of the first one.
    registering[id] = .now
    do {
      return try await deliverAndStart(config, session: requested, instance: instance, context: context)
    } catch {
      // GitHub has a registration now, so *any* failure below has to drop it — including one that
      // never made it into the row.
      await failAfterIssue(requested, runnerID: config.runnerID, error: error, context: context)
      throw error
    }
  }

  /// Spec §48 step 14: as late as practical, and only once the guest is proven up.
  private func issueJIT(
    instance: InstanceRecord, context: SessionContext
  ) async throws -> JITRunnerConfig {
    switch context.origin {
    case .rest:
      guard let plane = context.plane else {
        throw OrchestrationError.githubNotConfigured(
          reason: "no GitHub credential provider is configured")
      }
      return try await plane.generateJITConfig(
        scope: context.scope,
        request: JITRunnerRequest(
          name: instance.name, labels: Self.labels(context.profile),
          runnerGroupID: context.scopeRecord?.runnerGroupId))
    case let .scaleSet(id):
      guard let plane = context.scaleSetPlane else {
        throw OrchestrationError.githubNotConfigured(
          reason: "no scale-set control plane is configured")
      }
      return try await plane.generateJITConfig(
        scope: context.scope, scaleSetID: id, runnerName: instance.name,
        workFolder: Self.defaultWorkFolder)
    }
  }

  /// Terminal state for a JIT request that never produced a config this caller could use.
  ///
  /// A plain failure (a 4xx/5xx `generate-jitconfig`) is what it has always been: GitHub refused,
  /// so nothing was created and the VM is kept for diagnosis. A *deadline* is different in both
  /// halves. GitHub may hold a registration nobody has seen — the config can have arrived after the
  /// race was already lost (`issued`), or the POST can have been processed with its answer still in
  /// flight (`strayRunnerID`) — and the id must reach the row, because `retryPendingRemovals` re-
  /// drives a failed DELETE from `githubRunnerId` alone. And a slow GitHub says nothing about this
  /// VM, so retaining it for `failedInstanceRetention` would let one outage eat the host's capacity
  /// one boot at a time.
  private func failJIT(
    _ session: RunnerSessionRecord, issued: Int64?, error: any Error, context: SessionContext
  ) async {
    // Closing out is a stage like any other, and it spends GitHub and guest calls of its own, so it
    // gets its own budget: the mark stamped for the JIT call is already `jitGeneration` old, and a
    // sweep that reached this row mid-teardown would close it under a second failure code and
    // remove the registration twice.
    registering[session.id] = .now
    guard let failure = error as? GitHubControlError, case .jitGenerationTimeout = failure else {
      await finish(session, to: .jitFailed, error: error, result: "jit-failed", context: context)
      return
    }
    var found = issued
    if found == nil {
      // Bounded by the same budget that just expired: the outage that caused the timeout must not
      // then park the caller -- and the VM it is holding -- inside the cleanup lookup.
      found = try? await withDeadline(
        Self.jitDeadline(context.profile), expired: { Self.jitTimedOut(context.profile) }
      ) { [self] in await strayRunnerID(session, context: context) }
    }
    if let runnerID = found {
      logger.warning(
        "JIT generation timed out but GitHub holds a registration; removing it",
        metadata: .context(instance: session.instanceId, session: session.id).merging([
          "runner_id": .stringConvertible(runnerID),
          "arrived_late": .stringConvertible(issued != nil),
        ]) { $1 })
      // `finish` is what removes it: the id reaches the terminal write through `pendingRunnerID`,
      // so the removal happens exactly once, bracketed by its `operations` row, and the column it
      // read is still there for `retryPendingRemovals`.
      pendingRunnerID[session.id] = runnerID
    } else {
      // "Not found" is not "does not exist": the lookup was made against the very GitHub that had
      // just stopped answering, and it is bounded, so a refusal and a real absence look the same
      // from here. This is the one path that can leave a registration with no id, no row and no
      // operation to retry from, so it says so where an operator will see it.
      var name = session.githubRunnerName
      if name == nil { name = (try? await instanceRows.get(id: session.instanceId))?.name }
      let advice = "JIT generation timed out and no registration could be found; if GitHub created "
        + "one it is orphaned and has to be removed by hand -- check `runnerctl runner list` and "
        + "the scope's runner settings on GitHub"
      logger.warning(
        "\(advice)",
        metadata: .context(instance: session.instanceId, session: session.id).merging([
          "runner_name": .string(name ?? "-"),
          "scope": .string(context.scope.description),
        ]) { $1 })
    }
    await finish(
      session, to: .jitFailed, error: error, result: "jit-failed", context: context,
      retainVM: false)
    pendingRunnerID[session.id] = nil
  }

  private func deliverAndStart(
    _ config: JITRunnerConfig, session: RunnerSessionRecord, instance: InstanceRecord,
    context: SessionContext
  ) async throws -> RunnerSessionRecord {
    var current = try await move(session, to: .jitIssued) { row in
      row.githubRunnerId = config.runnerID
      row.githubRunnerName = config.runnerName
      row.jitIssuedAt = .now
    }
    try await deliver(config, session: current, instance: instance)
    current = try await move(current, to: .jitDelivered) { $0.jitDeliveredAt = .now }
    current = try await move(current, to: .runnerStarting) { $0.runnerStartedAt = .now }
    try await instances.advanceRunnerState(id: instance.id, to: .runnerStarting)
    logger.info(
      "runner session started",
      metadata: .context(
        profile: current.profileId, instance: instance.id, session: current.id,
        githubRunnerID: current.githubRunnerId, githubRunnerName: current.githubRunnerName
      ).merging(["scope": .string(context.scope.description)]) { $1 })
    observe(current, context: context)
    return current
  }

  /// Terminal state for a failure that happened after the JIT config was issued. `finish` refuses
  /// an illegal edge, so the target has to match wherever the row actually got to.
  private func failAfterIssue(
    _ session: RunnerSessionRecord, runnerID: Int64, error: any Error, context: SessionContext
  ) async {
    let current = (try? await sessions.get(id: session.id)) ?? session
    guard !current.state.isTerminal else { return }
    if current.githubRunnerId == nil {
      // The `jitIssued` write itself failed, so the row cannot drive the removal: use the id in
      // hand before it is lost with this stack frame.
      await ensureRunnerRemoved(
        session: current.id, runnerID: runnerID, scope: context.scope,
        source: context.origin.source)
    }
    let target: RunnerSessionState = current.state == .jitRequested ? .jitFailed : .runnerStartFailed
    await finish(current, to: target, error: error, result: "start-failed", context: context)
  }

  /// The row lands before the JIT request so a crash in between leaves something to reconcile.
  /// `id` comes from `register`, which marks it `registering` before this insert publishes it.
  private func insertRow(
    id: RunnerSessionID, instance: InstanceRecord, context: SessionContext
  ) async throws -> RunnerSessionRecord {
    let now = DatabaseDate.now
    let record = RunnerSessionRecord(
      id: id, instanceId: instance.id, profileId: instance.profileId,
      jitSource: context.origin.source, state: .planned, createdAt: now, updatedAt: now)
    do {
      try await sessions.insert(record)
    } catch {
      await instances.abandonForRunnerSession(
        id: instance.id, code: "RUNNER_SESSION_NOT_PERSISTED",
        message: "could not create the runner session row: \(error)")
      throw error
    }
    return record
  }

  /// Spec §36: the only place the JIT secret is read. It reaches the guest over vmworker's
  /// peer-checked Unix socket and is gone from this process when the call returns.
  private func deliver(
    _ config: JITRunnerConfig, session: RunnerSessionRecord, instance: InstanceRecord
  ) async throws {
    let request = StartRunnerRequest(
      sessionId: session.id.rawValue, jitConfig: config.encodedJITConfig, workDir: nil, env: [:],
      labels: nil)
    do {
      _ = try await instances.startRunner(id: instance.id, request)
    } catch {
      // `agent.startRunner` is single-shot: a failed reply may still have spawned the runner, and
      // a blind retry would be answered `ALREADY_STARTED`. Ask the agent what actually happened.
      guard await startedAnyway(instance: instance, session: session) else { throw error }
      logger.warning(
        "startRunner reply lost; the guest reports the runner is up",
        metadata: .context(instance: instance.id, session: session.id))
    }
  }

  private func startedAnyway(
    instance: InstanceRecord, session: RunnerSessionRecord
  ) async -> Bool {
    guard let status = try? await instances.runnerStatus(
      id: instance.id, sessionId: session.id.rawValue) else { return false }
    return status.state != .unknown
  }

  /// Spec §36 registers the runner under the profile name; `self-hosted` is the label every
  /// workflow already targets.
  static func labels(_ profile: RunnerProfileConfig) -> [String] {
    ["self-hosted", profile.name]
  }

  // MARK: - Transitions

  /// Every session state change goes through the repository's compare-and-swap, so a background
  /// observer and a foreground command can never both move the same row.
  @discardableResult
  func move(
    _ session: RunnerSessionRecord, to state: RunnerSessionState,
    mutate: @escaping @Sendable (inout RunnerSessionRecord) -> Void = { _ in }
  ) async throws -> RunnerSessionRecord {
    // See `pendingRunnerID`: a runner id discovered as the row is being closed has no other write
    // to travel on. Read, never removed here -- `settle` retries `move` once after a lost CAS, and
    // the second attempt has to carry the id too.
    let pending = pendingRunnerID[session.id]
    let updated = try await sessions.transition(
      id: session.id, from: session.state, to: state,
      mutate: { row in
        if let pending, row.githubRunnerId == nil { row.githubRunnerId = pending }
        mutate(&row)
      })
    logger.debug(
      "runner session transition",
      metadata: .context(
        profile: session.profileId, instance: session.instanceId, session: session.id,
        githubRunnerID: updated.githubRunnerId, githubRunnerName: updated.githubRunnerName
      ).merging([
        "from": .string(session.state.rawValue), "to": .string(state.rawValue),
      ]) { $1 })
    await events?.record(
      LifecycleEventLog.sessionTransition,
      LifecycleEventLog.Fields(
        instance: session.instanceId, profile: session.profileId, session: session.id,
        githubRunnerID: updated.githubRunnerId, from: session.state.rawValue, to: state.rawValue,
        reason: updated.failureCode))
    return updated
  }
}

/// The runner id a JIT call produced, published from inside the deadline race so a caller that has
/// already given up can still name the registration GitHub made for it.
///
/// A box rather than a bare `Mutex` local because `Mutex` is non-copyable and cannot be captured by
/// the escaping body closure `withDeadline` runs. It holds the id and nothing else: the encoded JIT
/// config is the secret and never outlives `register`'s local `let` (spec §36, §128).
private final class IssuedRunnerID: Sendable {
  private let id = Mutex<Int64?>(nil)

  func publish(_ value: Int64) {
    id.withLock { $0 = value }
  }

  var current: Int64? {
    id.withLock { $0 }
  }
}
