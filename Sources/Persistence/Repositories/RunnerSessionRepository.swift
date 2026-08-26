import GRDB
import RunnerCore

public protocol RunnerSessionRepository: Sendable {
  func insert(_ session: RunnerSessionRecord) async throws
  func get(id: RunnerSessionID) async throws -> RunnerSessionRecord?
  /// Sessions for `instance` whose state is not `RunnerSessionState.isTerminal`.
  func listActive(instance: InstanceID) async throws -> [RunnerSessionRecord]
  /// Newest first. `limit` bounds what `runner.list` has to render on a long-lived host.
  func list(limit: Int?) async throws -> [RunnerSessionRecord]

  /// Single write transaction. CAS on `state` (`PersistenceError.staleWrite` if it isn't `from`),
  /// validated against `RunnerSessionState.canTransition` (`StateTransitionError` on an illegal
  /// edge). `updated_at` is stamped by the repository after `mutate` runs, regardless of what
  /// `mutate` set — it is bookkeeping the repository owns.
  @discardableResult
  func transition(
    id: RunnerSessionID, from: RunnerSessionState, to: RunnerSessionState,
    mutate: @Sendable (inout RunnerSessionRecord) -> Void
  ) async throws -> RunnerSessionRecord
}

public final class GRDBRunnerSessionRepository: RunnerSessionRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func insert(_ session: RunnerSessionRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "runner_sessions") { try session.insert(db) }
    }
  }

  public func get(id: RunnerSessionID) async throws -> RunnerSessionRecord? {
    try await db.read { db in try RunnerSessionRecord.fetchOne(db, key: id) }
  }

  public func listActive(instance: InstanceID) async throws -> [RunnerSessionRecord] {
    try await db.read { db in
      let terminal = RunnerSessionState.allCases.filter(\.isTerminal).map(\.rawValue)
      return try RunnerSessionRecord
        .filter(Column("instance_id") == instance.rawValue)
        .filter(!terminal.contains(Column("state")))
        .fetchAll(db)
    }
  }

  public func list(limit: Int?) async throws -> [RunnerSessionRecord] {
    try await db.read { db in
      var request = RunnerSessionRecord.order(Column("created_at").desc)
      if let limit { request = request.limit(limit) }
      return try request.fetchAll(db)
    }
  }

  public func transition(
    id: RunnerSessionID, from: RunnerSessionState, to: RunnerSessionState,
    mutate: @Sendable (inout RunnerSessionRecord) -> Void
  ) async throws -> RunnerSessionRecord {
    try await db.write { db in
      guard var record = try RunnerSessionRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "runner_sessions", id: id.rawValue)
      }
      guard record.state == from else {
        throw PersistenceError.staleWrite(
          entity: "runner_sessions", id: id.rawValue, expectedState: from.rawValue, actualState: record.state.rawValue
        )
      }
      record.state = try from.transitioned(to: to)
      mutate(&record)
      record.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "runner_sessions") { try record.update(db) }
      return record
    }
  }
}
