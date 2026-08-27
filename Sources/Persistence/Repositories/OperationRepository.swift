import GRDB
import RunnerCore

public protocol OperationRepository: Sendable {
  /// Starts (and marks `.running`) a new operation, or — when `idempotencyKey` is non-`nil` and
  /// already recorded — returns the existing row unchanged (spec §119 "operations should be
  /// resumable"; a crashed-and-retried caller must not double-start work).
  @discardableResult
  func start(
    kind: String, resourceType: String, resourceId: String, idempotencyKey: String?
  ) async throws -> OperationRecord

  /// Like `start`, but only a *still-running* row wins the idempotency key: a terminal row with
  /// the same key has its key cleared and a fresh operation is inserted. A retried image pull must
  /// not adopt the failed operation of the attempt before it, while a pull resumed after a daemon
  /// crash (whose row is still `running`) must adopt exactly that one (spec §119).
  @discardableResult
  func restart(
    kind: String, resourceType: String, resourceId: String, idempotencyKey: String
  ) async throws -> OperationRecord

  /// `metadataJson`, when given, replaces the row's metadata: the place a finished operation
  /// leaves a result its caller could not know up front (the immutable reference a push landed on).
  func finish(
    id: OperationID, state: OperationState, errorCode: String?, errorMessage: String?,
    metadataJson: String?
  ) async throws
  func list(state: OperationState?) async throws -> [OperationRecord]
}

public final class GRDBOperationRepository: OperationRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func start(
    kind: String, resourceType: String, resourceId: String, idempotencyKey: String?
  ) async throws -> OperationRecord {
    try await db.write { db in
      if let idempotencyKey,
        let existing = try OperationRecord.filter(Column("idempotency_key") == idempotencyKey).fetchOne(db)
      {
        return existing
      }
      let record = OperationRecord(
        id: OperationID.generate(), kind: kind, resourceType: resourceType, resourceId: resourceId,
        state: .running, idempotencyKey: idempotencyKey, startedAt: .now
      )
      try DatabaseErrorMapper.run(entity: "operations") { try record.insert(db) }
      return record
    }
  }

  public func restart(
    kind: String, resourceType: String, resourceId: String, idempotencyKey: String
  ) async throws -> OperationRecord {
    try await db.write { db in
      if var existing = try OperationRecord
        .filter(Column("idempotency_key") == idempotencyKey).fetchOne(db)
      {
        if existing.state == .running || existing.state == .pending { return existing }
        // `idempotency_key` is UNIQUE, so the finished row has to release it first.
        existing.idempotencyKey = nil
        try DatabaseErrorMapper.run(entity: "operations") { try existing.update(db) }
      }
      let record = OperationRecord(
        id: OperationID.generate(), kind: kind, resourceType: resourceType, resourceId: resourceId,
        state: .running, idempotencyKey: idempotencyKey, startedAt: .now
      )
      try DatabaseErrorMapper.run(entity: "operations") { try record.insert(db) }
      return record
    }
  }

  public func finish(
    id: OperationID, state: OperationState, errorCode: String?, errorMessage: String?,
    metadataJson: String?
  ) async throws {
    try await db.write { db in
      guard var record = try OperationRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "operations", id: id.rawValue)
      }
      record.state = state
      record.finishedAt = .now
      record.errorCode = errorCode
      record.errorMessage = errorMessage
      if let metadataJson { record.metadataJson = metadataJson }
      try DatabaseErrorMapper.run(entity: "operations") { try record.update(db) }
    }
  }

  public func list(state: OperationState?) async throws -> [OperationRecord] {
    try await db.read { db in
      if let state {
        try OperationRecord.filter(Column("state") == state.rawValue).fetchAll(db)
      } else {
        try OperationRecord.fetchAll(db)
      }
    }
  }
}

extension OperationRepository {
  public func finish(
    id: OperationID, state: OperationState, errorCode: String?, errorMessage: String?
  ) async throws {
    try await finish(
      id: id, state: state, errorCode: errorCode, errorMessage: errorMessage, metadataJson: nil)
  }
}
