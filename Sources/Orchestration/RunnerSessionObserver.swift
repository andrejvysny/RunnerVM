import DaemonAPI
import Foundation
import GitHubControl
import GuestControl
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// Spec §48 steps 18-23: watch the runner, then take the VM down.
///
/// Everything here is driven by `agent.runnerStatus` plus the instance row. There is no push
/// channel from the guest, and there deliberately isn't one: a poll that finds a dead VM is the
/// same code path as a poll that finds a finished job.
extension RunnerSessionManager {
  /// `remove-runner` operations carry this idempotency prefix so a retry reuses the same row.
  static let removalOperationKind = "remove-runner"

  func observe(_ session: RunnerSessionRecord, context: SessionContext) {
    let id = session.id
    observers[id] = Task { [weak self] in
      await self?.watch(session, context: context)
      await self?.clearObserver(id)
    }
  }

  func clearObserver(_ id: RunnerSessionID) {
    observers[id] = nil
  }

  private func watch(_ started: RunnerSessionRecord, context: SessionContext) async {
    var session = started
    var sawBusy = false
    var lostPolls = 0
    while !Task.isCancelled {
      do { try await Task.sleep(for: tuning.pollInterval) } catch { return }
      guard await instanceIsLive(session) else {
        await abandon(session, code: "VM_LOST", reason: "the VM left its runner state",
                      sawBusy: sawBusy, context: context)
        return
      }
      guard let status = try? await instances.runnerStatus(
        id: session.instanceId, sessionId: session.id.rawValue)
      else {
        lostPolls += 1
        guard lostPolls >= tuning.lostPollThreshold else { continue }
        await abandon(
          session, code: "RUNNER_STATUS_UNAVAILABLE", reason: "the guest agent stopped answering",
          sawBusy: sawBusy, context: context)
        return
      }
      lostPolls = 0
      guard let next = await apply(status, to: session, sawBusy: sawBusy, context: context)
      else { return }
      session = next.session
      sawBusy = next.sawBusy
      if await enforceDeadlines(session, context: context) { return }
    }
  }

  private func instanceIsLive(_ session: RunnerSessionRecord) async -> Bool {
    guard let instance = try? await instanceRows.get(id: session.instanceId) else { return false }
    return Self.liveInstanceStates.contains(instance.state)
  }

  /// `nil` means the session is terminal and the loop must stop.
  private func apply(
    _ status: RunnerStatus, to session: RunnerSessionRecord, sawBusy: Bool,
    context: SessionContext
  ) async -> (session: RunnerSessionRecord, sawBusy: Bool)? {
    switch status.state {
    case .starting:
      return (session, sawBusy)
    case .online:
      // Ignored once a job has been seen: a JIT runner that finished its job reports `exited`,
      // and finishing early on a momentary `online` would cut the upload of the job's logs.
      guard session.state == .runnerStarting else { return (session, sawBusy) }
      if let online = try? await markOnline(session) { return (online, sawBusy) }
      return (await refreshed(session), sawBusy)
    case .busy:
      guard let running = try? await markBusy(session) else {
        return (await refreshed(session), sawBusy)
      }
      return (running, true)
    case .exited:
      // A JIT runner is single-use: GitHub removes the registration itself once the job ends, so
      // the happy path deliberately issues no DELETE (spec §36).
      await finish(
        session, to: .completed, result: sawBusy ? "job" : "no-job", context: context)
      return nil
    case .unknown:
      await abandon(
        session, code: "RUNNER_PROCESS_UNKNOWN", reason: "the agent no longer knows the session",
        sawBusy: sawBusy, context: context)
      return nil
    }
  }

  /// Instance row first, session row second. The two tables are never written in one
  /// transaction, so the order is the invariant: a session that reads `runnerOnline`/`jobRunning`
  /// sits on an instance that already reads `runnerOnline`/`busy`. Readers of the instance row
  /// (taint, orchestrator, operators) therefore never see a VM lagging behind its own session.
  private func markOnline(_ session: RunnerSessionRecord) async throws -> RunnerSessionRecord {
    try await instances.advanceRunnerState(id: session.instanceId, to: .runnerOnline)
    return try await move(session, to: .runnerOnline) { $0.runnerOnlineAt = .now }
  }

  private func markBusy(_ session: RunnerSessionRecord) async throws -> RunnerSessionRecord {
    let online = session.state == .runnerStarting ? try await markOnline(session) : session
    guard online.state == .runnerOnline else { return online }
    try await instances.advanceRunnerState(id: session.instanceId, to: .busy)
    return try await move(online, to: .jobRunning) { $0.jobStartedAt = .now }
  }

  /// A failed compare-and-swap means the row moved under the observer; polling on with the
  /// in-memory copy would make every later CAS fail too and the terminal write impossible.
  private func refreshed(_ session: RunnerSessionRecord) async -> RunnerSessionRecord {
    (try? await sessions.get(id: session.id)) ?? session
  }

  /// Returns true when a deadline fired and the session is now terminal.
  private func enforceDeadlines(
    _ session: RunnerSessionRecord, context: SessionContext
  ) async -> Bool {
    let timeouts = context.profile.effectiveTimeouts
    if session.state == .runnerStarting,
       Self.expired(session.runnerStartedAt, limit: timeouts.runnerOnline) {
      await timeOut(session, code: "RUNNER_ONLINE_TIMEOUT", context: context)
      return true
    }
    if session.state == .jobRunning,
       Self.expired(session.jobStartedAt, limit: timeouts.jobMaxRuntime) {
      await timeOut(session, code: "JOB_MAX_RUNTIME_EXCEEDED", context: context)
      return true
    }
    return false
  }

  private func timeOut(
    _ session: RunnerSessionRecord, code: String, context: SessionContext
  ) async {
    _ = try? await instances.stopRunner(
      id: session.instanceId, sessionId: session.id.rawValue, graceMs: tuning.stopGraceMs)
    await finish(
      session, to: .timedOut, failureCode: code, result: "timed-out", context: context)
  }

  private func abandon(
    _ session: RunnerSessionRecord, code: String, reason: String, sawBusy: Bool,
    context: SessionContext
  ) async {
    let state: RunnerSessionState = session.state == .jobRunning ? .jobInterrupted : .runnerLost
    logger.warning(
      "runner session abandoned",
      metadata: .context(instance: session.instanceId, session: session.id).merging([
        "reason": .string(reason), "saw_job": .stringConvertible(sawBusy),
      ]) { $1 })
    await finish(
      session, to: state, failureCode: code, result: "interrupted", context: context)
  }

  private static func expired(_ since: DatabaseDate?, limit: DurationValue) -> Bool {
    guard let since, limit.isPositive else { return false }
    let parts = limit.duration.components
    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    return Date().timeIntervalSince(since.date) >= seconds
  }

  // MARK: - Terminal

  /// The single exit from a session: persist the terminal state, write the job summary, remove
  /// the runner from GitHub when the session did not end cleanly, and take the VM down
  /// (spec §48 steps 21-23, `docs/state_machines.md`).
  func finish(
    _ session: RunnerSessionRecord, to state: RunnerSessionState, error: (any Error)? = nil,
    failureCode: String? = nil, result: String?, context: SessionContext
  ) async {
    let code = (error as? any RunnerError)?.code ?? failureCode
    let terminal: RunnerSessionRecord
    do {
      terminal = try await move(session, to: state) { row in
        row.result = result
        row.failureCode = code
        if row.jobStartedAt != nil || state == .completed { row.jobFinishedAt = .now }
      }
    } catch {
      logger.error(
        "could not close the runner session",
        metadata: .context(session: session.id).merging([
          "target": .string(state.rawValue), "error": .string(String(describing: error)),
        ]) { $1 })
      return
    }
    await recordJobSummary(terminal)
    await recordSessionMetrics(terminal, profile: context.profile.name)
    if state.requiresRunnerRemoval, let runnerID = terminal.githubRunnerId {
      await ensureRunnerRemoved(
        session: terminal.id, runnerID: runnerID, scope: context.scope,
        source: terminal.jitSource)
    }
    await teardown(terminal, context: context, failed: state != .completed)
    logger.info(
      "runner session finished",
      metadata: .context(instance: terminal.instanceId, session: terminal.id).merging([
        "state": .string(state.rawValue), "result": .string(result ?? "-"),
        "failure": .string(code ?? "-"),
      ]) { $1 })
  }

  /// Idempotent and durable: the attempt is bracketed by an `operations` row keyed on the session,
  /// so a GitHub outage leaves a `failed` marker the maintenance loop retries instead of a runner
  /// GitHub keeps handing jobs to (spec §119, §134).
  func ensureRunnerRemoved(
    session: RunnerSessionID, runnerID: Int64, scope: GitHubScope, source: JitSource
  ) async {
    let operation = try? await operations.start(
      kind: Self.removalOperationKind, resourceType: "runner_session",
      resourceId: session.rawValue,
      idempotencyKey: "\(Self.removalOperationKind):\(session.rawValue)")
    do {
      try await removeRunner(scope: scope, runnerID: runnerID, source: source)
      await close(operation, error: nil)
    } catch {
      logger.warning(
        "runner removal failed; queued for retry",
        metadata: .context(session: session).merging([
          "runner_id": .stringConvertible(runnerID),
          "error": .string(String(describing: error)),
        ]) { $1 })
      await close(operation, error: error)
    }
  }

  /// A scale-set runner is removed through the scale-set API, not the REST runners endpoint: the
  /// registration belongs to the scale set, and the two are not interchangeable (spec §50).
  private func removeRunner(scope: GitHubScope, runnerID: Int64, source: JitSource) async throws {
    switch source {
    case .scaleSet:
      guard let plane = await gateway.scaleSetControlPlane() else {
        throw OrchestrationError.githubNotConfigured(
          reason: "no scale-set control plane while removing runner \(runnerID)")
      }
      try await plane.ensureRunnerRemoved(scope: scope, runnerID: runnerID)
    case .rest:
      guard let plane = await gateway.controlPlane() else {
        throw OrchestrationError.githubNotConfigured(
          reason: "no GitHub client while removing runner \(runnerID)")
      }
      try await plane.ensureRunnerRemoved(scope: scope, runnerID: runnerID)
    }
  }

  private func close(_ operation: OperationRecord?, error: (any Error)?) async {
    guard let operation else { return }
    let runnerError = error as? any RunnerError
    try? await operations.finish(
      id: operation.id, state: error == nil ? .succeeded : .failed,
      errorCode: error == nil ? nil : (runnerError?.code ?? "INTERNAL"),
      errorMessage: error.map { runnerError?.message ?? String(describing: $0) })
  }

  /// Retries the removals a GitHub outage left behind. Called from the daemon's slow loop.
  @discardableResult
  public func retryPendingRemovals() async -> Int {
    guard let pending = try? await operations.list(state: .failed) else { return 0 }
    var retried = 0
    for operation in pending where operation.kind == Self.removalOperationKind {
      guard let session = try? await sessions.get(id: RunnerSessionID(rawValue: operation.resourceId)),
            let runnerID = session.githubRunnerId,
            let scope = await scopeForProfile(session.profileId)
      else { continue }
      do {
        try await removeRunner(scope: scope, runnerID: runnerID, source: session.jitSource)
        try? await operations.finish(
          id: operation.id, state: .succeeded, errorCode: nil, errorMessage: nil)
        retried += 1
      } catch {
        continue
      }
    }
    return retried
  }

  private func scopeForProfile(_ id: RunnerProfileID) async -> GitHubScope? {
    guard let profile = try? await profiles.list().first(where: { $0.id == id }),
          let record = try? await scopes.list().first(where: { $0.id == profile.scopeId })
    else { return nil }
    return try? GitHubMapping.scope(record)
  }

  // MARK: - Teardown

  /// Hands the VM back to `InstanceManager`, which owns the instance state machine: an ephemeral
  /// profile is retired (kept on failure, for `failure.json`), a reusable one goes
  /// `busy -> cleaning -> idle` unless something on the §126 list says it may not be trusted.
  private func teardown(
    _ session: RunnerSessionRecord, context: SessionContext, failed: Bool
  ) async {
    let startedAt = ContinuousClock.now
    await instances.afterSession(
      id: session.instanceId, session: session.id, profile: context.profile,
      outcome: SessionOutcome(
        completed: !failed,
        failureCode: session.failureCode ?? (failed ? "RUNNER_SESSION_FAILED" : nil),
        detail: "runner session \(session.id.rawValue) ended as \(session.state.rawValue)",
        publicRepositoryScope: context.scopeRecord.isPublicRepository == true))
    // `afterSession` is where a reusable VM is wiped and an ephemeral one is retired, so the call
    // itself is the cleanup window spec §41 asks about; `InstanceReuse` owns the steps inside it.
    await instances.metricRegistry().observe(
      RunnerVMMetrics.cleanupSeconds,
      labels: [RunnerVMMetrics.profileLabel: context.profile.name], since: startedAt)
  }

  /// Spec §41. Every timing here comes from the session and instance rows, which is the only
  /// place a full lifecycle is visible at once; a daemon restart mid-session simply produces no
  /// observation rather than a wrong one.
  private func recordSessionMetrics(_ session: RunnerSessionRecord, profile: String) async {
    let metrics = await instances.metricRegistry()
    let labels = [RunnerVMMetrics.profileLabel: profile]
    await metrics.increment(
      RunnerVMMetrics.sessionsTotal,
      labels: labels.merging([RunnerVMMetrics.resultLabel: session.state.rawValue]) { $1 })
    await observe(
      metrics, RunnerVMMetrics.jitGenerationSeconds, labels: labels,
      from: session.createdAt.date, to: session.jitIssuedAt?.date)
    await observe(
      metrics, RunnerVMMetrics.jitDeliveryToRunnerOnlineSeconds, labels: labels,
      from: session.jitDeliveredAt?.date, to: session.runnerOnlineAt?.date)
    await observe(
      metrics, RunnerVMMetrics.jobDurationSeconds, labels: labels,
      from: session.jobStartedAt?.date, to: session.jobFinishedAt?.date)
  }

  private func observe(
    _ metrics: MetricRegistry, _ name: String, labels: [String: String], from: Date?, to: Date?
  ) async {
    guard let from, let to, to >= from else { return }
    await metrics.observe(name, labels: labels, seconds: to.timeIntervalSince(from))
  }

  /// Spec §48 step 21. Durations come from the instance and session timestamps; the guest-side
  /// memory/CPU peaks belong to the metrics sampler and stay `nil` until M9.
  private func recordJobSummary(_ session: RunnerSessionRecord) async {
    guard let instance = try? await instanceRows.get(id: session.instanceId) else { return }
    let summary = JobSummaryRecord(
      id: UUID().uuidString.lowercased(),
      runnerSessionId: session.id,
      cloneDurationMs: Self.millis(instance.createdAt.date, instance.startedAt?.date),
      bootDurationMs: Self.millis(instance.startedAt?.date, instance.agentReadyAt?.date),
      agentReadyDurationMs: Self.millis(instance.agentReadyAt?.date, session.runnerOnlineAt?.date),
      jobDurationMs: Self.millis(session.jobStartedAt?.date, session.jobFinishedAt?.date),
      createdAt: .now)
    try? await summaries.insert(summary)
  }

  private static func millis(_ from: Date?, _ to: Date?) -> Int? {
    guard let from, let to, to >= from else { return nil }
    return Int((to.timeIntervalSince(from) * 1_000).rounded())
  }
}
