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

  func finish(id: OperationID, state: OperationState, errorCode: String?, errorMessage: String?) async throws
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

  public func finish(id: OperationID, state: OperationState, errorCode: String?, errorMessage: String?) async throws {
    try await db.write { db in
      guard var record = try OperationRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "operations", id: id.rawValue)
      }
      record.state = state
      record.finishedAt = .now
      record.errorCode = errorCode
      record.errorMessage = errorMessage
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
