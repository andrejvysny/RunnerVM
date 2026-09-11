import Foundation
import GitHubControl
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// Spec §69: after a `runnerd` restart every persisted non-terminal `runner_sessions` row is
/// either re-observed or closed out.
///
/// `observers` is in-memory only, so a daemon that dies mid-session leaves rows nobody is
/// watching: capacity the scheduler still counts as busy (`OrchestratorTick`), VMs nobody will
/// hand back, and GitHub registrations that would keep receiving jobs no VM will ever run.
///
/// Recovery is deliberately at-most-once. The JIT config is never persisted (spec §36, §45), so
/// it can never be re-delivered: a session whose runner cannot be re-observed is failed, not
/// restarted. Re-observing is safe because `agent.runnerStatus` is a read — the guest, not the
/// daemon, is the authority on whether the runner is still up.
extension RunnerSessionManager {
  /// What one sweep did. `deferred` counts sessions this sweep deliberately left alone -- an
  /// observer is already watching them, a `register` still owns them, or they moved under the
  /// snapshot -- which is what makes repeating the sweep on every reconcile tick free.
  public struct RecoveryReport: Sendable, Hashable {
    public var reattached = 0
    public var terminalized = 0
    public var deferred = 0

    public init() {}
  }

  /// The failure code every session closed purely because the daemon went away carries.
  static let restartFailureCode = "DAEMON_RESTART"
  /// `runner_sessions.result` for the same. Distinct from `"interrupted"`: nothing went wrong on
  /// the VM or at GitHub, the daemon simply stopped watching.
  static let restartResult = "recovered"

  /// Only reachable if the schema's foreign keys were violated, since `runner_sessions` →
  /// `runner_profiles` → `github_scopes` are all enforced. The session still has to be closed
  /// out; a GitHub call made against this scope fails and is queued as a retryable operation row.
  static let unresolvedScope = GitHubScope.organization(owner: "", runnerGroupID: nil)

  /// Idempotent, and safe to call on every tick: a session already being observed -- or still
  /// being registered -- is skipped, and a terminal row is not a session any more.
  public func recoverSessions() async -> RecoveryReport {
    var report = RecoveryReport()
    guard let rows = try? await sessions.list(limit: nil) else { return report }
    for row in rows where !row.state.isTerminal {
      guard observers[row.id] == nil else {
        report.deferred += 1
        continue
      }
      let from = row.state
      let context = await contextForRecovery(row)
      // A `register` between its row insert and its first observer owns this row: it is parked in
      // a JIT call with nothing to defer to, and closing the session under it would drop the
      // registration GitHub is about to hand back and tear the VM down mid-call. Checking the mark
      // after `contextForRecovery` is safe, and needed for the profile's own `jitGeneration`: for a
      // row that is already in `rows` the mark can only disappear (its `register` finished, which
      // also moved the row), never appear.
      guard !isRegistering(row.id, within: Self.registrationGrace(context.profile)) else {
        report.deferred += 1
        continue
      }
      // Anything still marked here is older than the grace -- a `register` that will never come
      // back -- so reap it: nothing else prunes the map, and `register`'s own `defer` is exactly
      // what such a caller never reached.
      registering[row.id] = nil
      let outcome = await recover(row, context: context)
      // Nothing happened, so nothing is recorded: a metric per tick per live session would be all
      // this sweep ever says.
      guard outcome != Self.skippedOutcome else {
        report.deferred += 1
        continue
      }
      switch outcome {
      case Self.reattachedOutcome: report.reattached += 1
      default: report.terminalized += 1
      }
      await record(row, from: from, outcome: outcome)
    }
    return report
  }

  static let reattachedOutcome = "reattached"
  static let terminalizedOutcome = "terminalized"
  /// The row moved, or somebody took ownership of it, between the snapshot and the decision.
  static let skippedOutcome = "skipped"

  private func record(
    _ session: RunnerSessionRecord, from: RunnerSessionState, outcome: String
  ) async {
    logger.info(
      "runner session recovered",
      metadata: .context(instance: session.instanceId, session: session.id).merging([
        "from": .string(from.rawValue), "outcome": .string(outcome),
      ]) { $1 })
    await instances.metricRegistry().increment(
      RunnerVMMetrics.sessionsRecoveredTotal,
      labels: [RunnerVMMetrics.outcomeLabel: outcome])
  }

  // MARK: - Per-state recovery

  /// Decides on a *re-read* row, never on the caller's snapshot.
  ///
  /// `rows` was listed and `contextForRecovery` awaited four more times before this call, and the
  /// manager is a reentrant actor: a `register`, an observer or a second sweep can have moved this
  /// row -- or taken ownership of it -- across any of those suspensions. Acting on the snapshot
  /// anyway would be fatal rather than merely wasted work, because `settle` deliberately re-targets
  /// its terminal CAS from whatever the row actually says: a session that has since gone
  /// `runnerOnline` would be closed and its VM destroyed under a live runner.
  private func recover(_ session: RunnerSessionRecord, context: SessionContext) async -> String {
    guard let fresh = try? await sessions.get(id: session.id), fresh.state == session.state,
          observers[session.id] == nil
    else { return Self.skippedOutcome }
    switch fresh.state {
    case .planned:
      // Nothing was asked of GitHub yet, so there is nothing to clean up there.
      await finish(
        fresh, to: .jitFailed, failureCode: Self.restartFailureCode,
        result: Self.restartResult, context: context,
        // Nothing to diagnose: the daemon went away, the VM did nothing wrong. Destroy it so the
        // capacity comes back now rather than after `failedInstanceRetention`.
        retainVM: false)
    case .jitRequested:
      // The POST may or may not have been processed before the daemon died; the runner's name is
      // the only handle on a registration whose id never reached the row.
      if let runnerID = await strayRunnerID(fresh, context: context) {
        await ensureRunnerRemoved(
          session: fresh.id, runnerID: runnerID, scope: context.scope,
          source: fresh.jitSource)
      }
      await finish(
        fresh, to: .jitFailed, failureCode: Self.restartFailureCode,
        result: Self.restartResult, context: context,
        // Nothing to diagnose: the daemon went away, the VM did nothing wrong. Destroy it so the
        // capacity comes back now rather than after `failedInstanceRetention`.
        retainVM: false)
    case .jitIssued:
      // The registration exists but its config never reached the guest, and it never will:
      // `finish` drops the runner and hands the VM back.
      await finish(
        fresh, to: .runnerStartFailed, failureCode: Self.restartFailureCode,
        result: Self.restartResult, context: context,
        // Nothing to diagnose: the daemon went away, the VM did nothing wrong. Destroy it so the
        // capacity comes back now rather than after `failedInstanceRetention`.
        retainVM: false)
    case .jitDelivered, .runnerStarting, .runnerOnline, .jobRunning:
      return await reattach(fresh, context: context)
    default:
      return Self.terminalizedOutcome
    }
    return Self.terminalizedOutcome
  }

  /// Re-adopts a session whose runner may still be running. The VM is the deciding evidence: no
  /// live instance row means no runner, whatever the session row last managed to write.
  private func reattach(_ session: RunnerSessionRecord, context: SessionContext) async -> String {
    guard let current = await normalized(session) else { return Self.terminalizedOutcome }
    let sawBusy = current.jobStartedAt != nil || current.state == .jobRunning
    guard let record = try? await instanceRows.get(id: current.instanceId),
          Self.liveInstanceStates.contains(record.state)
    else {
      await abandon(
        current, code: "VM_LOST", reason: "the VM did not survive the daemon restart",
        sawBusy: sawBusy, context: context)
      return Self.terminalizedOutcome
    }
    await alignInstance(record, to: current.state)
    // From here the ordinary observer owns the session: its first poll reconciles whatever the
    // guest actually reports, including a runner that has already exited.
    observe(current, context: context, sawBusy: sawBusy)
    return Self.reattachedOutcome
  }

  /// `jitDelivered` is the one non-terminal state with no edge to any lost state — its only exits
  /// are `runnerStarting` and `runnerStartFailed` — so a row stuck there is walked forward before
  /// anything tries to abandon it. The runner either started or never will; both are `runnerStarting`
  /// as far as the observer is concerned.
  private func normalized(_ session: RunnerSessionRecord) async -> RunnerSessionRecord? {
    guard session.state == .jitDelivered else { return session }
    return try? await move(session, to: .runnerStarting) { row in
      row.runnerStartedAt = row.runnerStartedAt ?? row.jitDeliveredAt ?? .now
    }
  }

  // MARK: - Instance ladder

  /// Walks the VM up to where the session already is.
  ///
  /// The session row is written before the instance row, so a daemon that died in between leaves
  /// the VM a step behind; every later `advanceRunnerState` would then be an illegal edge and the
  /// session could never be closed. An instance that is already level or ahead is left alone.
  private func alignInstance(_ instance: InstanceRecord, to state: RunnerSessionState) async {
    let ladder: [InstanceState] = [.runnerStarting, .runnerOnline, .busy]
    guard let target = Self.instanceState(for: state),
          let end = ladder.firstIndex(of: target) else { return }
    for step in ladder[...end] {
      guard let current = try? await instanceRows.get(id: instance.id),
            current.state.allowedTransitions.contains(step) else { continue }
      _ = try? await instances.advanceRunnerState(id: instance.id, to: step)
    }
  }

  static func instanceState(for state: RunnerSessionState) -> InstanceState? {
    switch state {
    case .runnerStarting: .runnerStarting
    case .runnerOnline: .runnerOnline
    case .jobRunning: .busy
    default: nil
    }
  }

  // MARK: - Stray registrations

  /// One lookup, never a retry loop: the daemon died somewhere around `generate-jitconfig`, so
  /// GitHub may or may not hold a registration under the VM's name. Blocking recovery behind a
  /// GitHub outage for a runner that probably does not exist would be a worse trade than leaving
  /// this one orphan to the operator.
  ///
  /// The plane that would have *issued* the registration is asked first, because that is the plane
  /// the removal will go back to (`removeRunner` switches on `jitSource`): a scale-set runner found
  /// through the REST listing is only useful if the two id spaces agree, while the scale-set
  /// listing is authoritative for it. The other plane stays as a fallback, since a registration
  /// that exists at all is better dropped through whichever API can see it.
  ///
  /// Also used by `register`'s JIT-deadline path, which is the live version of the same question:
  /// the POST may have been processed after the caller stopped waiting for the answer.
  func strayRunnerID(
    _ session: RunnerSessionRecord, context: SessionContext
  ) async -> Int64? {
    guard let instance = try? await instanceRows.get(id: session.instanceId) else { return nil }
    if session.jitSource == .scaleSet, let plane = context.scaleSetPlane,
       let found = try? await plane.runner(scope: context.scope, name: instance.name) {
      return found.id
    }
    guard let plane = context.plane,
          let runner = try? await plane.findRunner(scope: context.scope, name: instance.name)
    else { return nil }
    return runner.id
  }

  // MARK: - Context

  /// Deliberately not `prepare`: recovery must work for a session whose scope has gone degraded,
  /// whose profile has been dropped from the configuration, or whose VM is no longer idle —
  /// every gate `prepare` applies is a reason a *new* session may not start, not a reason an
  /// existing one may not be closed.
  func contextForRecovery(_ session: RunnerSessionRecord) async -> SessionContext {
    let profileRow = (try? await profiles.list())?.first { $0.id == session.profileId }
    let scopeRecord = await recoveryScope(profileRow)
    return SessionContext(
      profile: profileRow.flatMap { try? $0.decodedConfig() } ?? Self.placeholderProfile(session),
      scopeRecord: scopeRecord,
      scope: scopeRecord.flatMap { try? GitHubMapping.scope($0) } ?? Self.unresolvedScope,
      // `.rest` throughout: `origin` only steers `issueJIT`, which recovery never reaches, while
      // the removal path switches on the row's own `jitSource`.
      plane: await gateway.controlPlane(), origin: .rest,
      scaleSetPlane: await gateway.scaleSetControlPlane())
  }

  private func recoveryScope(_ profile: RunnerProfileRecord?) async -> GitHubScopeRecord? {
    guard let profile else { return nil }
    return (try? await scopes.list())?.first { $0.id == profile.scopeId }
  }

  /// Defaults, so a session whose profile is gone is still torn down: `ephemeral` retires the VM
  /// rather than returning an unverifiable one to the pool, which is the safe reading.
  private static func placeholderProfile(_ session: RunnerSessionRecord) -> RunnerProfileConfig {
    RunnerProfileConfig(
      name: session.profileId.rawValue, scope: "", image: "", guestOS: .linux)
  }
}

/// Runs `recoverSessions` on every reconcile tick (spec §69: every step is idempotent, so a tick
/// is always safe to repeat). The first tick does the real work after a restart; later ones catch
/// a session whose observer task died without closing its row.
public struct RunnerSessionReconciler: ReconcileStep {
  private let runners: RunnerSessionManager

  public init(runners: RunnerSessionManager) {
    self.runners = runners
  }

  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    var counts = ReconcileCounts()
    counts.sessionsTerminalized = await runners.recoverSessions().terminalized
    return counts
  }
}
