import ConfigLoader
import Foundation
import Network
import Persistence
import RPC
import RunnerCore
import Testing

@testable import Orchestration

/// Phase 0 item 0.1(b): every way `DaemonRuntime.startStages` can fail has to reach launchd as a
/// sysexits code an operator can act on, and a supervised runnerd has to stay dead long enough
/// that the failure is visible instead of scrolling past in a respawn loop.
@Suite struct StartupFailureTests {
  private struct Row {
    let label: String
    let error: any Error
    let expected: StartupFailureClass
  }

  private static let issue = ConfigurationIssue.error("X", "profiles[0]", "bad")

  /// A function, not a `static let`: `Row` holds an `any Error`, which is not `Sendable`.
  private static func rows() -> [Row] {
    [
      // 78 EX_CONFIG — the document is wrong; nothing on the host has to change.
      Row(label: "config syntax", error: ConfigurationError.syntaxInvalid(path: "/c.yaml", reason: "x"),
        expected: .configuration),
      Row(label: "config validation", error: ConfigurationError.validationFailed(issues: [issue]),
        expected: .configuration),
      Row(label: "config unreadable (loader)",
        error: ConfigurationError.fileUnreadable(path: "/c.yaml", cause: nil), expected: .configuration),
      Row(label: "socket path too long",
        error: ConfigurationError.socketPathTooLong(path: "/x", bytes: 120, limit: 100),
        expected: .configuration),
      Row(label: "config unreadable (bootstrap)",
        error: OrchestrationError.configUnreadable(path: "/c.yaml", reason: "ENOENT"),
        expected: .configuration),
      Row(label: "config rejected", error: OrchestrationError.configRejected(issues: [issue]),
        expected: .configuration),
      // The loader's own errors escape `startStages` raw (`DaemonServiceImpl.configApply`); they
      // are matched by their `CONFIG_*` code because Orchestration cannot import ConfigLoader.
      Row(label: "yaml syntax (loader)",
        error: ConfigLoadError.yamlSyntax(line: 3, column: 1, message: "x"), expected: .configuration),
      Row(label: "unknown key (loader)", error: ConfigLoadError.unknownKey(path: "host.bogus"),
        expected: .configuration),
      Row(label: "unsupported version (loader)", error: ConfigLoadError.unsupportedVersion(99),
        expected: .configuration),
      Row(label: "schema newer than build",
        error: PersistenceError.schemaVersionUnsupported(found: 9, supported: 4),
        expected: .configuration),
      Row(label: "socket path too long (RPC)", error: RPCServerError.socketPathTooLong("/x"),
        expected: .configuration),

      // 72 EX_OSFILE — the state directory, its database or its identity file is not usable.
      Row(label: "state dir not creatable", error: CocoaError(.fileWriteNoPermission),
        expected: .environment),
      Row(label: "ENOSPC", error: CocoaError(.fileWriteOutOfSpace), expected: .environment),
      Row(label: "host identity unwritable",
        error: OrchestrationError.hostIdentityUnwritable(path: "/s/host-id", reason: "EROFS"),
        expected: .environment),
      Row(label: "database corrupted", error: PersistenceError.corrupted(reason: "malformed"),
        expected: .environment),
      Row(label: "migration failed", error: PersistenceError.migrationFailed(version: 4, reason: "x"),
        expected: .environment),
      Row(label: "lock errno with no verdict",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: ENOENT),
        expected: .environment),
      Row(label: "unknown error", error: UnknownStartupError(), expected: .environment),
      // Retryable for the scheduler ("try another VM"), permanent for startup.
      Row(label: "vmworker missing at startup",
        error: VMError.workerSpawnFailed(reason: "no vmworker executable found", cause: nil),
        expected: .environment),

      // 69 EX_UNAVAILABLE — something runnerd needs is held or taken.
      Row(label: "lock EACCES",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: EACCES),
        expected: .unavailable),
      Row(label: "lock EPERM",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: EPERM),
        expected: .unavailable),
      Row(label: "lock EROFS",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: EROFS),
        expected: .unavailable),
      Row(label: "socket bind", error: RPCServerError.posix(operation: "bind", errno: EADDRINUSE),
        expected: .unavailable),
      Row(label: "metrics port bind", error: NWError.posix(.EADDRINUSE), expected: .unavailable),

      // 75 EX_TEMPFAIL — clears by itself; starting again is the right response.
      Row(label: "database busy", error: PersistenceError.busy(reason: "locked"), expected: .transient),
      Row(label: "lost CAS",
        error: PersistenceError.staleWrite(entity: "hosts", id: "h", expectedState: "a", actualState: "b"),
        expected: .transient),
      Row(label: "incumbent daemon",
        error: OrchestrationError.daemonAlreadyRunning(path: "/s/runnerd.lock"), expected: .transient),
      Row(label: "lock EMFILE",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: EMFILE),
        expected: .transient),
      Row(label: "lock ENFILE",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: ENFILE),
        expected: .transient),
      Row(label: "lock ENOMEM",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: ENOMEM),
        expected: .transient),
      Row(label: "lock EAGAIN",
        error: OrchestrationError.lockUnavailable(path: "/s/runnerd.lock", errno: EAGAIN),
        expected: .transient),
      Row(label: "cancelled", error: CancellationError(), expected: .transient),
    ]
  }

  private struct UnknownStartupError: Error {}

  @Test func everyStartupErrorLandsInItsClass() {
    for row in Self.rows() {
      #expect(StartupFailure.classify(row.error) == row.expected, "\(row.label)")
    }
  }

  @Test func eachClassCarriesItsSysexitsCode() {
    #expect(StartupFailureClass.configuration.exitCode == 78)
    #expect(StartupFailureClass.environment.exitCode == 72)
    #expect(StartupFailureClass.unavailable.exitCode == 69)
    #expect(StartupFailureClass.transient.exitCode == 75)
    // A class added without an exit code of its own would collide here.
    #expect(Set(StartupFailureClass.allCases.map(\.exitCode)).count == StartupFailureClass.allCases.count)
  }

  /// The raw GRDB error `RunnerDatabase.open` can throw is not a `RunnerError`, so it has to land
  /// in the fail-closed branch rather than in a respawn loop. Opening a path that is a directory
  /// produces a genuine one (SQLITE_CANTOPEN) without reaching for GRDB in this target.
  @Test func rawDatabaseLibraryErrorsFailClosed() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let url = tree.root.appending(path: "runnerd.sqlite3")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    do {
      _ = try RunnerDatabase.open(at: url)
      Issue.record("expected RunnerDatabase.open to fail on a path that is a directory")
    } catch {
      #expect(!(error is any RunnerError))
      #expect(StartupFailure.classify(error) == .environment)
    }
  }

  /// `retryable` is the primary signal, so it must not silently disagree with the classifier.
  /// The three documented overrides are the whole exception list; a fourth one showing up here is
  /// a design change, not a test failure to paper over.
  @Test func classificationAgreesWithRetryable() {
    let overrides = ["DAEMON_ALREADY_RUNNING", "DAEMON_LOCK_UNAVAILABLE", "VM_WORKER_SPAWN_FAILED"]
    for row in Self.rows() {
      guard let error = row.error as? any RunnerError, !overrides.contains(error.code) else { continue }
      #expect((StartupFailure.classify(error) == .transient) == error.retryable, "\(row.label)")
    }
  }

  @Test func backoffReadsTheEnvironmentAndClampsIt() {
    #expect(StartupFailure.backoff(environment: [:]) == .seconds(60))
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "0"]) == .zero)
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "120"]) == .seconds(120))
    // Junk and negatives fall back to the default rather than to zero: a typo must not turn the
    // backoff off.
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "abc"]) == .seconds(60))
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "-5"]) == .seconds(60))
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "9999"]) == .seconds(300))
  }

  @Test func supervisionIsParentPIDOrTheEnvironmentFlag() {
    #expect(StartupFailure.isSupervised(environment: [:], parentPID: 1))
    #expect(!StartupFailure.isSupervised(environment: [:], parentPID: 4_242))
    #expect(StartupFailure.isSupervised(environment: ["RUNNERVM_SUPERVISED": "1"], parentPID: 4_242))
    #expect(!StartupFailure.isSupervised(environment: ["RUNNERVM_SUPERVISED": "0"], parentPID: 4_242))
  }

  @Test func thePlanSleepsOnlyUnderASupervisor() {
    let config = ConfigurationError.syntaxInvalid(path: "/c.yaml", reason: "x")
    let plan = StartupFailure.plan(
      for: config, environment: [:], supervised: false, consecutiveTransientFailures: 0)
    #expect(plan == StartupExitPlan(failureClass: .configuration, exitCode: 78, sleep: .zero))
  }

  @Test func theTransientPlanEscalatesAfterTenFailuresInARow() {
    let busy = PersistenceError.busy(reason: "locked")
    func sleep(after failures: Int) -> Duration {
      StartupFailure.plan(
        for: busy, environment: [:], supervised: true, consecutiveTransientFailures: failures).sleep
    }
    #expect(sleep(after: 0) == .seconds(5))
    #expect(sleep(after: 9) == .seconds(5))
    #expect(sleep(after: 10) == .seconds(60))
    #expect(sleep(after: 99) == .seconds(60))
    // Escalation lands on the configured backoff, not on a second hardcoded constant.
    let tuned = StartupFailure.plan(
      for: busy, environment: ["RUNNERVM_STARTUP_BACKOFF": "120"], supervised: true,
      consecutiveTransientFailures: 10)
    #expect(tuned == StartupExitPlan(failureClass: .transient, exitCode: 75, sleep: .seconds(120)))
  }

  @Test func nonTransientClassesSleepTheConfiguredBackoff() {
    let errors: [any Error] = [
      ConfigurationError.syntaxInvalid(path: "/c.yaml", reason: "x"),
      CocoaError(.fileWriteOutOfSpace),
      RPCServerError.posix(operation: "bind", errno: EADDRINUSE),
    ]
    for error in errors {
      let plan = StartupFailure.plan(
        for: error, environment: ["RUNNERVM_STARTUP_BACKOFF": "30"], supervised: true,
        consecutiveTransientFailures: 0)
      #expect(plan.sleep == .seconds(30), "\(plan.failureClass.rawValue)")
    }
  }

  @Test func theCounterRoundTripsThroughTheRuntimeDirectory() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    try FileManager.default.createDirectory(at: tree.paths.runtimeDir, withIntermediateDirectories: true)
    let counter = StartupAttemptCounter(runtimeDir: tree.paths.runtimeDir)

    #expect(counter.consecutiveTransientFailures() == 0)
    #expect(counter.record(transient: true) == 1)
    #expect(counter.record(transient: true) == 2)
    #expect(StartupAttemptCounter(runtimeDir: tree.paths.runtimeDir).consecutiveTransientFailures() == 2)
    // A non-transient failure is a different failure: the transient streak is over.
    #expect(counter.record(transient: false) == 0)
    #expect(counter.consecutiveTransientFailures() == 0)
    #expect(counter.record(transient: true) == 1)
    counter.reset()
    #expect(counter.consecutiveTransientFailures() == 0)
  }

  /// A counter nobody can read or write escalates rather than pinning runnerd to the 5 s respawn.
  @Test func anUnreadableCounterEscalates() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let runtimeDir = tree.paths.runtimeDir
    try FileManager.default.createDirectory(
      at: runtimeDir.appending(path: StartupAttemptCounter.fileName), withIntermediateDirectories: true)
    let counter = StartupAttemptCounter(runtimeDir: runtimeDir)

    #expect(counter.consecutiveTransientFailures() == StartupFailure.transientEscalationThreshold)
    #expect(counter.record(transient: true) == StartupFailure.transientEscalationThreshold)
    let plan = StartupFailure.plan(
      for: PersistenceError.busy(reason: "locked"), environment: [:], supervised: true,
      consecutiveTransientFailures: counter.record(transient: true))
    #expect(plan.sleep == .seconds(60))
  }

  @Test func backoffTrimsATrailingNewline() {
    #expect(StartupFailure.backoff(environment: ["RUNNERVM_STARTUP_BACKOFF": "30\n"]) == .seconds(30))
  }
}
