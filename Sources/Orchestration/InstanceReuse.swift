import Foundation
import GuestControl
import Persistence
import RunnerCore
import RunnerLogging

/// Taint vocabulary (spec §126). Persisted in `instances.taint_reason` and shown by `vm show`;
/// kept as constants rather than an enum because the column is free text and older rows written
/// by an earlier build must still render.
public enum TaintReason {
  public static let cleanupFailed = "CLEANUP_FAILED"
  public static let agentDegraded = "AGENT_DEGRADED"
  public static let unexpectedReboot = "UNEXPECTED_REBOOT"
  public static let diskPressure = "DISK_PRESSURE"
  public static let sessionFailed = "SESSION_FAILED"
  public static let diskLost = "DISK_LOST"
  public static let manual = "MANUAL"
}

/// Ways the cleaning window can end without the VM being trustworthy again. `GuestAgentError`
/// covers the guest-side faults; these are the host's own verdicts.
public enum ReuseFailure: RunnerError {
  case diskPressure(availableBytes: Int64, totalBytes: Int64)
  case cleanupRejected
  case timedOut(DurationValue)

  public var code: String {
    switch self {
    case .diskPressure: "INSTANCE_DISK_PRESSURE"
    case .cleanupRejected: "INSTANCE_CLEANUP_REJECTED"
    case .timedOut: "INSTANCE_CLEANUP_TIMEOUT"
    }
  }

  public var message: String {
    switch self {
    case let .diskPressure(available, total):
      "guest root filesystem has \(ByteSize(bytes: UInt64(max(0, available)))) free of "
        + "\(ByteSize(bytes: UInt64(max(0, total))))"
    case .cleanupRejected: "the guest agent reported the cleanup did not succeed"
    case let .timedOut(limit): "cleanup did not finish within \(limit)"
    }
  }

  public var retryable: Bool { false }
}

/// What a finished runner session says about the VM it ran on.
public struct SessionOutcome: Sendable {
  public var completed: Bool
  public var failureCode: String?
  public var detail: String
  /// Spec §9.2: reuse is documented as weaker isolation, so a public repository never gets it
  /// regardless of the profile's `lifecycle`.
  public var publicRepositoryScope: Bool

  public init(
    completed: Bool, failureCode: String? = nil, detail: String,
    publicRepositoryScope: Bool = false
  ) {
    self.completed = completed
    self.failureCode = failureCode
    self.detail = detail
    self.publicRepositoryScope = publicRepositoryScope
  }
}

/// Why a VM is not going back to `idle`. `taint` non-nil means the VM is no longer trusted;
/// `failureCode` non-nil routes the teardown through `interrupted` so the reason survives on the
/// row and in `failure.json`.
struct ReuseVerdict: Sendable {
  var reason: String
  var taint: String?
  var failureCode: String?
  var detail: String = ""
}

/// The reusable VM lifecycle: `busy → cleaning → idle`, and every reason not to take it
/// (spec §9.2, §46, §126).
///
/// Lives on `InstanceManager` rather than beside `RunnerSessionManager` because it moves VM
/// state, and the VM state machine has exactly one owner. `RunnerSessionManager.finish` calls
/// `afterSession` and is done.
extension InstanceManager {
  /// States a dead worker may be restarted from (spec §72): the VM held no job, so its disk is
  /// as consistent as the last cleanup left it.
  static let reusableRestartStates: Set<InstanceState> = [.idle, .cleaning]

  /// Spec §126 "disk usage > threshold". A VM with less than this much root headroom would fail
  /// the next job on it, so it is recycled instead.
  static let minimumFreeDiskFraction = 0.10

  // MARK: - Entry point

  /// Called once per finished runner session. Increments the job counter, then either cleans the
  /// VM back to `idle` or recycles it.
  public func afterSession(
    id: InstanceID, session: RunnerSessionID, profile: RunnerProfileConfig,
    outcome: SessionOutcome
  ) async {
    guard let record = try? await instances.applyReuse(id: id, ReuseUpdate(consumeJob: true))
    else { return }
    guard profile.lifecycle == .reusable, let policy = profile.effectiveReuse else {
      await retireEphemeral(record, outcome: outcome)
      return
    }
    if let verdict = Self.verdict(record, policy: policy, outcome: outcome, now: tuning.now()) {
      await recycle(record, verdict)
      return
    }
    await clean(record, session: session, profile: profile)
  }

  /// Plan C1 "Reusable cleanup": back to `idle` only if nothing on this list fired.
  static func verdict(
    _ record: InstanceRecord, policy: ReusePolicy, outcome: SessionOutcome, now: Date
  ) -> ReuseVerdict? {
    if outcome.publicRepositoryScope {
      return ReuseVerdict(reason: "public-repository")
    }
    if record.tainted {
      return ReuseVerdict(reason: "tainted", taint: record.taintReason ?? TaintReason.manual)
    }
    if record.retireAfterSession {
      return ReuseVerdict(reason: "retire-after-session")
    }
    if !outcome.completed {
      guard policy.recycleOnFailure else { return nil }
      return ReuseVerdict(
        reason: "session-failed", taint: TaintReason.sessionFailed,
        failureCode: outcome.failureCode ?? "RUNNER_SESSION_FAILED", detail: outcome.detail)
    }
    if policy.maxJobs > 0, record.jobsConsumed >= policy.maxJobs {
      return ReuseVerdict(reason: "max-jobs")
    }
    if policy.maxAge.isPositive,
       now.timeIntervalSince(record.createdAt.date) >= Self.seconds(policy.maxAge) {
      return ReuseVerdict(reason: "max-age")
    }
    return nil
  }

  // MARK: - Cleaning

  private func clean(
    _ record: InstanceRecord, session: RunnerSessionID, profile: RunnerProfileConfig
  ) async {
    guard let cleaning = try? await enterCleaning(record) else {
      await recycle(
        record,
        ReuseVerdict(
          reason: "cleaning-unreachable", taint: TaintReason.cleanupFailed,
          detail: "the VM left its runner states before it could be cleaned"))
      return
    }
    let timeout = profile.effectiveTimeouts.cleanup
    do {
      try await withDeadline(timeout) { [self] in
        try await runCleanup(cleaning, session: session)
      }
    } catch {
      let runnerError = error as? any RunnerError
      await recycle(
        cleaning,
        ReuseVerdict(
          reason: "cleanup-failed", taint: Self.taint(for: error),
          failureCode: runnerError?.code ?? "AGENT_CLEANUP_FAILED",
          detail: runnerError?.message ?? String(describing: error)))
      return
    }
    guard let idle = try? await transition(cleaning, to: .idle, mutate: { $0.lastSeenAt = .now })
    else { return }
    logger.info(
      "instance returned to the pool",
      metadata: .context(instance: record.id).merging([
        "jobs_consumed": .stringConvertible(idle.jobsConsumed),
      ]) { $1 })
  }

  /// Spec §46 makes `busy -> cleaning` the only edge into `cleaning`. A runner that exited
  /// without ever picking up a job leaves the VM short of `busy`, so it is walked forward rather
  /// than retired for a job it never ran.
  private func enterCleaning(_ record: InstanceRecord) async throws -> InstanceRecord {
    var current = record
    for state in [InstanceState.runnerStarting, .runnerOnline, .busy] {
      guard current.state != .busy, current.state.allowedTransitions.contains(state) else {
        continue
      }
      current = try await transition(current, to: state)
    }
    return try await transition(current, to: .cleaning)
  }

  /// Spec §9.2 cleanup list, then the three proofs the VM is still the one we booted: the agent
  /// is ready, the guest did not reboot, and the root filesystem still has room.
  private func runCleanup(_ record: InstanceRecord, session: RunnerSessionID) async throws {
    let client = try await agentClient(record.id)
    // Best effort: the happy path reaches here because the runner already exited.
    _ = try? await client.stopRunner(
      StopRunnerRequest(sessionId: session.rawValue, graceMs: tuning.gracefulShutdownMs))
    // `epoch` is `jobs_consumed` after this session's increment, so a retry of the same session
    // replays the same epoch and the agent answers it as a no-op.
    let cleanup = try await client.cleanup(epoch: Int64(record.jobsConsumed))
    guard cleanup.ok else { throw ReuseFailure.cleanupRejected }
    let health = try await client.health()
    guard health.isReady else {
      throw GuestAgentError.unhealthy(reason: health.reasons.joined(separator: "; "))
    }
    let hello = try await client.hello()
    if let expected = record.bootId, hello.bootId != expected {
      throw GuestAgentError.bootIDChanged(previous: expected, current: hello.bootId)
    }
    try Self.assertDiskHeadroom(try await client.getMetrics())
  }

  static func assertDiskHeadroom(_ metrics: GuestMetrics) throws {
    let disk = metrics.disk
    guard disk.rootTotalBytes > 0 else { return }
    let floor = Double(disk.rootTotalBytes) * minimumFreeDiskFraction
    guard Double(disk.rootAvailableBytes) < floor else { return }
    throw ReuseFailure.diskPressure(
      availableBytes: disk.rootAvailableBytes, totalBytes: disk.rootTotalBytes)
  }

  static func taint(for error: any Error) -> String {
    switch error {
    case let guest as GuestAgentError:
      switch guest {
      case .bootIDChanged: TaintReason.unexpectedReboot
      case .unhealthy, .notReady, .handshakeFailed, .protocolVersionUnsupported:
        TaintReason.agentDegraded
      default: TaintReason.cleanupFailed
      }
    case let reuse as ReuseFailure:
      if case .diskPressure = reuse { TaintReason.diskPressure } else { TaintReason.cleanupFailed }
    default:
      TaintReason.cleanupFailed
    }
  }

  // MARK: - Teardown

  /// Spec §126: never return a failed-cleanup VM to idle.
  func recycle(_ record: InstanceRecord, _ verdict: ReuseVerdict) async {
    if let taint = verdict.taint {
      _ = try? await instances.applyReuse(
        id: record.id, ReuseUpdate(tainted: true, taintReason: taint))
    }
    logger.notice(
      "recycling instance",
      metadata: .context(instance: record.id).merging([
        "reason": .string(verdict.reason), "taint": .string(verdict.taint ?? "-"),
      ]) { $1 })
    if let code = verdict.failureCode {
      await interrupt(record.id, code: code, message: verdict.detail)
    } else {
      _ = try? await stop(id: record.id, force: false)
    }
    _ = try? await delete(id: record.id)
  }

  /// Spec §48 step 22 / §74: one job, then the VM goes — unless the session failed, in which case
  /// the directory and its `failure.json` are the only evidence of why.
  private func retireEphemeral(_ record: InstanceRecord, outcome: SessionOutcome) async {
    guard outcome.completed else {
      await interrupt(
        record.id, code: outcome.failureCode ?? "RUNNER_SESSION_FAILED", message: outcome.detail)
      return
    }
    _ = try? await stop(id: record.id, force: false)
    _ = try? await delete(id: record.id)
  }

  static func seconds(_ value: DurationValue) -> Double {
    let parts = value.duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}

/// Races `body` against the cleaning deadline (`timeouts.cleanup`, spec §73). A guest that hangs
/// mid-cleanup must not park the VM in `cleaning` forever.
func withDeadline<T: Sendable>(
  _ timeout: DurationValue, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  guard timeout.isPositive else { return try await body() }
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: timeout.duration)
      throw ReuseFailure.timedOut(timeout)
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw ReuseFailure.timedOut(timeout) }
    return first
  }
}
