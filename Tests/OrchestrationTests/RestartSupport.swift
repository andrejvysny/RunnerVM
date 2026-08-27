import Foundation
import GRDB
import GitHubControl
import Logging
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// What a `runnerd` restart looks like from a test's side, plus the row surgery needed to describe
/// the window a crash landed in.
extension M2Harness {
  /// The `RunnerSessionManager` the next daemon builds: same database, same instance manager, same
  /// gateway — and an empty `observers` map, which is the whole problem recovery solves.
  func restartedRunners() async -> RunnerSessionManager {
    var tuning = RunnerSessionManager.Tuning()
    tuning.pollInterval = .milliseconds(5)
    tuning.lostPollThreshold = 2
    let manager = RunnerSessionManager(
      sessions: GRDBRunnerSessionRepository(db: database), instanceRows: instanceRows,
      profiles: GRDBProfileRepository(db: database), scopes: GRDBScopeRepository(db: database),
      summaries: GRDBJobSummaryRepository(db: database),
      operations: GRDBOperationRepository(db: database), instances: instances, gateway: gateway,
      tuning: tuning)
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
  func instanceReconciler() -> InstanceReconciler {
    let manager = instances
    return InstanceReconciler(
      instances: instanceRows, manager: manager, supervisor: supervisor, store: instanceStore,
      retention: { await manager.failedInstanceRetention() }, images: images,
      logger: Logger(label: "test"))
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
}
