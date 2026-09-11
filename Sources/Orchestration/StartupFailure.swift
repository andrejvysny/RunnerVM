import Foundation
import Network
import RPC
import RunnerCore

/// Why `runnerd` could not start, and therefore what its supervisor should do about it.
///
/// launchd cannot read a log, so the exit code is the only thing it — and the operator reading
/// `launchctl print` — gets. The four classes map onto sysexits(3) so `last exit code` alone says
/// whether a human has to change something (78/72/69) or whether waiting is enough (75).
public enum StartupFailureClass: String, Sendable, CaseIterable {
  /// The configuration document is wrong: parsed, rejected, or newer than this build.
  case configuration
  /// The host is not usable: state directory, host identity, database file, no space.
  case environment
  /// Something the daemon needs is held or taken: the lock, the socket, the metrics port.
  case unavailable
  /// Clears by itself; starting again is the right response.
  case transient

  /// sysexits(3). Literals rather than the `EX_*` macros, matching `WorkerExitCode`.
  public var exitCode: Int32 {
    switch self {
    case .configuration: 78  // EX_CONFIG
    case .environment: 72  // EX_OSFILE
    case .unavailable: 69  // EX_UNAVAILABLE
    case .transient: 75  // EX_TEMPFAIL
    }
  }
}

/// What `runnerd` does about a failed `DaemonRuntime.start()`: how long to stay dead before
/// exiting, and with which code.
public struct StartupExitPlan: Equatable, Sendable {
  public var failureClass: StartupFailureClass
  public var exitCode: Int32
  /// Time to sleep *before* exiting. Always `.zero` when nothing is supervising this process.
  public var sleep: Duration

  public init(failureClass: StartupFailureClass, exitCode: Int32, sleep: Duration) {
    self.failureClass = failureClass
    self.exitCode = exitCode
    self.sleep = sleep
  }
}

/// Startup failure policy, pure and testable: `runnerd` only calls `plan` and obeys it.
///
/// The in-process sleep exists because `ThrottleInterval` cannot be relied on — `runnerctl
/// upgrade` does not re-render the launchd plists, so an upgraded host keeps whatever throttle it
/// was installed with. Sleeping here bounds the respawn rate whatever the plist says.
public enum StartupFailure {
  /// Operator override for the non-transient backoff, in seconds. Both launchd plists set it.
  public static let backoffVariable = "RUNNERVM_STARTUP_BACKOFF"
  /// Set by both launchd plists; belt and braces next to the `getppid() == 1` test, which is
  /// wrong in exactly one case that matters — a debugger or `launchctl bootstrap`-less manual run.
  public static let supervisedVariable = "RUNNERVM_SUPERVISED"

  public static let defaultBackoffSeconds = 60
  public static let maximumBackoffSeconds = 300
  /// A transient failure sleeps briefly: the incumbent daemon may still be shutting down.
  public static let transientBackoffSeconds = 5
  /// …but a host that has produced this many transient failures in a row is not transient any
  /// more, so it falls back to the configuration backoff instead of spinning at 5 s forever.
  public static let transientEscalationThreshold = 10

  // MARK: - Classification

  public static func classify(_ error: any Error) -> StartupFailureClass {
    if let overridden = override(for: error) { return overridden }
    // Primary signal (spec §84): a domain error that says it clears by itself is transient.
    if let runnerError = error as? any RunnerError, runnerError.retryable { return .transient }
    return fixed(for: error)
  }

  /// The complete set of startup errors whose class is NOT `retryable`'s verdict. Keep it short:
  /// a new entry means a domain error whose flag is lying about startup, and the flag is usually
  /// the thing to fix instead.
  private static func override(for error: any Error) -> StartupFailureClass? {
    // `VMError.retryable` is true for a spawn failure because another VM attempt is worth it;
    // a missing vmworker helper at startup will not appear by respawning.
    if let vm = error as? VMError, case .workerSpawnFailed = vm { return .environment }
    // A cancelled bind (`MetricsEndpoint` reports one this way) or a cancelled startup: nothing
    // is wrong with the host, so let the supervisor try again.
    if error is CancellationError { return .transient }
    guard let orchestration = error as? OrchestrationError else { return nil }
    return switch orchestration {
    // `retryable: false` because no *request* should be retried — but a supervisor should: the
    // incumbent daemon may be halfway through its own shutdown.
    case .daemonAlreadyRunning: .transient
    case let .lockUnavailable(_, code): lockClass(errno: code)
    default: nil
    }
  }

  /// The lock file could not even be opened, and only the errno says whose problem that is.
  /// `nil` falls through to the fail-closed table below (ENOENT, ENOTDIR, ENOSPC land there).
  private static func lockClass(errno code: Int32) -> StartupFailureClass? {
    switch code {
    // Wrong owner, wrong mode, or a read-only filesystem: a human has to act.
    case EACCES, EPERM, EROFS: .unavailable
    // Descriptor or memory exhaustion: nothing about the install is wrong, wait it out.
    case EMFILE, ENFILE, ENOMEM, EAGAIN: .transient
    default: nil
    }
  }

  /// Non-retryable errors, by what a human would have to do about them. The default is 72 rather
  /// than 75: an unrecognised startup failure that respawns every few seconds is worse than one
  /// that stops, so this fails closed.
  private static func fixed(for error: any Error) -> StartupFailureClass {
    if error is ConfigurationError { return .configuration }
    // `ConfigLoader` sits above this module, so its `ConfigLoadError` (YAML syntax, unknown key,
    // unsupported version, ...) is only reachable by code. Every `CONFIG_*` code is a document
    // problem, not a host problem — and it is the failure a managed host hits most often, because
    // both plists pass `--config`.
    if let runnerError = error as? any RunnerError, runnerError.code.hasPrefix("CONFIG_") {
      return .configuration
    }
    if let orchestration = error as? OrchestrationError {
      switch orchestration {
      case .configUnreadable, .configRejected: return .configuration
      // The host id file lives beside the database, so a write failure is a state-dir fault.
      case .hostIdentityUnwritable: return .environment
      default: return .environment
      }
    }
    if let persistence = error as? PersistenceError {
      switch persistence {
      // A database newer than this build is a packaging/rollback decision, not a host fault.
      case .schemaVersionUnsupported: return .configuration
      case .corrupted, .migrationFailed: return .environment
      default: return .environment
      }
    }
    if let rpc = error as? RPCServerError {
      switch rpc {
      // bind/listen/chmod/rename on runnerd.sock: the control surface is not available.
      case .posix: return .unavailable
      // Same condition `ConfigurationError.socketPathTooLong` reports, so the same class.
      case .socketPathTooLong: return .configuration
      case .notStarted, .alreadyStarted: return .environment
      }
    }
    // `NWListener` could not bind the metrics port — usually another process already has it.
    if error is NWError { return .unavailable }
    // Raw Foundation filesystem errors (`createDirectory`, `Data.write`), ENOSPC among them.
    // Deliberately not transient: a full disk does not clear on its own.
    if error is CocoaError { return .environment }
    // Raw GRDB `DatabaseError` and anything this build has never seen land here as well.
    return .environment
  }

  // MARK: - Policy

  /// Seconds from `RUNNERVM_STARTUP_BACKOFF`, clamped to `0...300`. Anything unparseable or
  /// negative is treated as absent rather than as zero — a typo must not disable the backoff.
  public static func backoff(environment: [String: String]) -> Duration {
    guard let raw = environment[backoffVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let seconds = Int(raw), seconds >= 0
    else { return .seconds(defaultBackoffSeconds) }
    return .seconds(min(seconds, maximumBackoffSeconds))
  }

  /// launchd reparents its jobs to PID 1, which is the honest signal here; `isatty` is not,
  /// because both plists pass `--foreground` exactly like an operator would.
  public static func isSupervised(
    environment: [String: String], parentPID: pid_t = getppid()
  ) -> Bool {
    parentPID == 1 || environment[supervisedVariable] == "1"
  }

  public static func plan(
    for error: any Error,
    environment: [String: String],
    supervised: Bool,
    consecutiveTransientFailures: Int
  ) -> StartupExitPlan {
    let failureClass = classify(error)
    // Unsupervised: an operator is watching the terminal, so exit immediately and let them read
    // the log instead of wondering why the process is hanging.
    guard supervised else {
      return StartupExitPlan(failureClass: failureClass, exitCode: failureClass.exitCode, sleep: .zero)
    }
    let configured = backoff(environment: environment)
    let sleep: Duration =
      if failureClass == .transient, consecutiveTransientFailures < transientEscalationThreshold {
        .seconds(transientBackoffSeconds)
      } else {
        configured
      }
    return StartupExitPlan(failureClass: failureClass, exitCode: failureClass.exitCode, sleep: sleep)
  }
}

/// Consecutive transient startup failures, persisted so the escalation survives the exit that
/// follows every one of them.
///
/// It lives in the runtime directory rather than the state directory on purpose: a broken state
/// directory is one of the failures being counted, and the runtime directory is the one launchd
/// itself needs anyway.
public struct StartupAttemptCounter: Sendable {
  public static let fileName = "startup-attempts"

  public let url: URL

  public init(runtimeDir: URL) {
    url = runtimeDir.appending(path: Self.fileName)
  }

  /// A counter that cannot be read is treated as already escalated: the safe direction is the
  /// long backoff, not a 5-second respawn loop driven by a file nobody can parse.
  public func consecutiveTransientFailures() -> Int {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return 0 }
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0
    else { return StartupFailure.transientEscalationThreshold }
    // Capped so a hand-edited or corrupt file cannot overflow the increment below. Any value past
    // the escalation threshold means the same thing anyway.
    return min(value, Self.maximumRecordedFailures)
  }

  /// Far above `transientEscalationThreshold`, so the number in the file stays honest in a log.
  private static let maximumRecordedFailures = 1_000_000

  /// Records one startup outcome and returns the resulting consecutive-transient count, which is
  /// what `StartupFailure.plan` wants. A write that fails escalates for the same reason a read
  /// that fails does.
  @discardableResult
  public func record(transient: Bool) -> Int {
    guard transient else {
      reset()
      return 0
    }
    let next = consecutiveTransientFailures() + 1
    return write(next) ? next : StartupFailure.transientEscalationThreshold
  }

  /// A clean start (or any non-transient failure) makes the next transient failure a first one.
  public func reset() {
    try? FileManager.default.removeItem(at: url)
  }

  /// `.atomic` writes a sibling temp file and renames, so a crash never leaves a partial count
  /// for the next boot to misread (same discipline as `HostIdentity`).
  private func write(_ value: Int) -> Bool {
    ((try? Data("\(value)\n".utf8).write(to: url, options: .atomic)) != nil)
  }
}
