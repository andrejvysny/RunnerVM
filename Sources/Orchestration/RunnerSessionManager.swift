import DaemonAPI
import Foundation
import GitHubControl
import GuestControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging

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
    /// SIGTERM-to-SIGKILL window when a timeout forces the runner down.
    public var stopGraceMs: Int64 = 30_000
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
  struct SessionContext: Sendable {
    let profileRow: RunnerProfileRecord
    let profile: RunnerProfileConfig
    let scopeRecord: GitHubScopeRecord
    let scope: GitHubScope
    let plane: any GitHubActionsControlPlane
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
      profileRow: profileRow, profile: try profileRow.decodedConfig(), scopeRecord: scopeRecord,
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

  private func register(
    instance: InstanceRecord, context: SessionContext
  ) async throws -> RunnerSessionRecord {
    let planned = try await insertRow(instance: instance, context: context)
    let requested = try await move(planned, to: .jitRequested)

    let config: JITRunnerConfig
    do {
      config = try await issueJIT(instance: instance, context: context)
    } catch {
      await finish(requested, to: .jitFailed, error: error, result: "jit-failed", context: context)
      throw error
    }
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
      return try await context.plane.generateJITConfig(
        scope: context.scope,
        request: JITRunnerRequest(
          name: instance.name, labels: Self.labels(context.profile),
          runnerGroupID: context.scopeRecord.runnerGroupId))
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
  private func insertRow(
    instance: InstanceRecord, context: SessionContext
  ) async throws -> RunnerSessionRecord {
    let now = DatabaseDate.now
    let record = RunnerSessionRecord(
      id: .generate(), instanceId: instance.id, profileId: context.profileRow.id,
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
    let updated = try await sessions.transition(
      id: session.id, from: session.state, to: state, mutate: mutate)
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
