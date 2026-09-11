import Foundation
import GRDB
import GitHubControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging
import Synchronization
import Testing

@testable import Orchestration

/// What a `runnerd` restart looks like from a test's side, plus the row surgery needed to describe
/// the window a crash landed in.
extension M2Harness {
  /// The `RunnerSessionManager` the next daemon builds: same database, same instance manager, same
  /// gateway — and an empty `observers` map, which is the whole problem recovery solves.
  ///
  /// `profiles` is overridable because it is fixed at `M2Harness` construction: a test that has to
  /// park the daemon inside the profile read `contextForRecovery` does injects its own. `logger`
  /// is, for the handful of assertions whose only evidence is a log line.
  func restartedRunners(
    profiles: (any ProfileRepository)? = nil, logger: Logger? = nil
  ) async -> RunnerSessionManager {
    var tuning = RunnerSessionManager.Tuning()
    tuning.pollInterval = .milliseconds(5)
    tuning.lostPollThreshold = 2
    let manager = RunnerSessionManager(
      sessions: GRDBRunnerSessionRepository(db: database), instanceRows: instanceRows,
      profiles: profiles ?? GRDBProfileRepository(db: database),
      scopes: GRDBScopeRepository(db: database),
      summaries: GRDBJobSummaryRepository(db: database),
      operations: GRDBOperationRepository(db: database), instances: instances,
      gateway: gateway, tuning: tuning, logger: logger ?? Logger(component: .runner))
    // The harness's event-driven waits (`awaitSession`, `awaitTerminal`) listen on this stream;
    // a restarted daemon attaches the same `events.jsonl` sink, so the replacement does too.
    await manager.attachEventLog(events)
    return manager
  }

  /// Everything a restart loses, and nothing it does not: the session observers, the guest bridges
  /// and the worker connections. The rows, the VMs and the guest agents survive, exactly as they do
  /// in production (`DaemonRuntime.teardown`).
  func simulateRestart() async {
    await runners.detachObservers()
    await instances.detachGuests()
    await supervisor.detachAll()
  }

  /// `InstanceReconciler` wired the way `DaemonRuntime` wires it. Its first tick re-adopts the
  /// surviving workers and re-handshakes the guests, which a restarted daemon needs before it can
  /// take any VM down.
  func instanceReconciler(
    now: @escaping @Sendable () -> Date = { Date() },
    deletingRetryGrace: Duration = .seconds(300)
  ) -> InstanceReconciler {
    let manager = instances
    return InstanceReconciler(
      instances: instanceRows, manager: manager, supervisor: supervisor, store: instanceStore,
      retention: { await manager.failedInstanceRetention() }, images: images, now: now,
      deletingRetryGrace: deletingRetryGrace, logger: Logger(label: "test"))
  }

  /// Rewrites a row past the state machine. The CAS in `transition` refuses to walk backwards --
  /// correctly -- so it cannot be used to describe where a dead daemon left things.
  func forceSessionState(_ id: RunnerSessionID, to state: RunnerSessionState) async throws {
    try await database.write { db in
      try db.execute(
        sql: "UPDATE runner_sessions SET state = ? WHERE id = ?",
        arguments: [state.rawValue, id.rawValue])
    }
  }

  func forceInstanceState(_ id: InstanceID, to state: InstanceState) async throws {
    try await database.write { db in
      try db.execute(
        sql: "UPDATE instances SET state = ? WHERE id = ?",
        arguments: [state.rawValue, id.rawValue])
    }
  }

  /// Same reason as `forceInstanceState`, one column lower: a crash window is described by the
  /// columns it left behind, and no CAS-guarded write path can produce a row that stopped an hour
  /// ago. The column name is a literal from the test, never anything read back from the database.
  func forceInstanceColumn(
    _ id: InstanceID, _ column: String, _ value: some DatabaseValueConvertible & Sendable
  ) async throws {
    try await database.write { db in
      try db.execute(
        sql: "UPDATE instances SET \(column) = ? WHERE id = ?", arguments: [value, id.rawValue])
    }
  }

  /// A non-terminal session row nobody is observing: what a daemon that died mid-registration
  /// leaves behind.
  @discardableResult
  func seedOrphanSession(
    instance: InstanceID, profile: String, state: RunnerSessionState,
    githubRunnerId: Int64? = nil, jitSource: JitSource = .rest
  ) async throws -> RunnerSessionID {
    let id = RunnerSessionID.generate()
    let now = DatabaseDate.now
    try await sessionRows.insert(
      RunnerSessionRecord(
        id: id, instanceId: instance, profileId: try await profileID(profile),
        jitSource: jitSource, githubRunnerId: githubRunnerId, state: state, createdAt: now,
        updatedAt: now))
    return id
  }

  func setScopeHealth(_ health: String, name: String = "test") async throws {
    var record = try #require(try await scopeRows.get(name: name))
    record.health = health
    try await scopeRows.upsert(record)
  }

  /// One runner registration under `name`, the way GitHub's `GET .../runners?name=` answers.
  func stubRunnerNamed(_ name: String, id: Int64 = M2Harness.runnerID) {
    let runner = "{\"id\":\(id),\"name\":\"\(name)\",\"os\":\"linux\","
      + "\"status\":\"offline\",\"busy\":false,\"labels\":[]}"
    github.stub(.get, Self.runnersPath, .json("{\"total_count\":1,\"runners\":[\(runner)]}"))
  }
}

extension RunnerSessionManager {
  /// The sessions this manager is watching. Every recovery test asserts at most one observer per
  /// session: that is what makes the sweep safe to repeat on every reconcile tick.
  func observedSessions() -> Set<RunnerSessionID> { Set(observers.keys) }

  /// Plants a `registering` mark the way `register` does, `age` old. The age rule cannot be reached
  /// by waiting -- the grace is the profile's `jitGeneration` plus slack -- and the mark is on a
  /// monotonic clock, so it cannot be reached by moving the wall clock either.
  func markRegistering(_ id: RunnerSessionID, age: Duration = .zero) {
    registering[id] = ContinuousClock.now - age
  }

  /// The very task watching `id`. `Task` compares by identity, so a test can prove a sweep left
  /// somebody else's observer in place rather than installing a second one over it.
  func observerTask(_ id: RunnerSessionID) -> Task<Void, Never>? { observers[id] }
}

/// Collects the lines a manager logged.
///
/// Some things a failure path does leave no row, metric or lifecycle event behind — telling the
/// operator that a registration may be orphaned on GitHub is one of them — and a log line is then
/// the whole observable. This reuses the production `JSONLogHandler` through its injectable sink,
/// so a test asserts on the line that really ships, redaction included.
final class LogSink: Sendable {
  private let lines = Mutex<[String]>([])

  var all: [String] { lines.withLock { $0 } }

  func record(_ line: String) {
    lines.withLock { $0.append(line) }
  }

  /// Lines at or above `warning` containing every one of `needles`.
  func warnings(_ needles: String...) -> [String] {
    all.filter { line in
      line.contains("\"level\":\"warning\"") || line.contains("\"level\":\"error\"")
    }
    .filter { line in needles.allSatisfy(line.contains) }
  }

  /// A `Logger` that writes only here. `LoggingSystem.bootstrap` is global and one-shot, so it can
  /// never be used from a suite that runs alongside every other one.
  func logger() -> Logger {
    Logger(label: "test") { label in
      JSONLogHandler(label: label, logLevel: .trace, sink: { [self] line in record(line) })
    }
  }
}

/// A one-shot async gate. An actor rather than a lock on purpose: a caller *parks* here, and an
/// `await` inside a held lock is exactly what must never happen in the code being faked.
actor SessionGate {
  private var parked: [CheckedContinuation<Void, Never>] = []
  private var opened = false
  /// How many callers have reached the gate. What a test waits on to know the daemon is parked
  /// exactly where it wants it -- and why arrival is counted before the park.
  private(set) var arrivals = 0

  func wait() async {
    arrivals += 1
    guard !opened else { return }
    await withCheckedContinuation { parked.append($0) }
  }

  /// Always call this, including on a failing path: a task still parked here is never cancellable
  /// and would hang the suite when its scope tries to await it.
  func open() {
    opened = true
    for continuation in parked { continuation.resume() }
    parked.removeAll()
  }
}

/// Parks the *first* `list()` on a gate. `contextForRecovery` reads the profile there, which is the
/// suspension `recoverSessions` has between listing the session rows and deciding on one of them --
/// the window in which the row it is holding can move.
actor GatedProfileRepository: ProfileRepository {
  private let wrapped: any ProfileRepository
  private let gate: SessionGate
  private var parkNext = true

  init(wrapping wrapped: any ProfileRepository, gate: SessionGate) {
    self.wrapped = wrapped
    self.gate = gate
  }

  func list() async throws -> [RunnerProfileRecord] {
    if parkNext {
      parkNext = false
      await gate.wait()
    }
    return try await wrapped.list()
  }

  func upsert(_ profile: RunnerProfileRecord) async throws { try await wrapped.upsert(profile) }
  func get(name: String) async throws -> RunnerProfileRecord? { try await wrapped.get(name: name) }
  func delete(name: String) async throws { try await wrapped.delete(name: name) }
}
