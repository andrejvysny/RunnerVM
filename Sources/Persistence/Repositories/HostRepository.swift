import GRDB
import RunnerCore

public protocol HostRepository: Sendable {
  /// Inserts the host row if absent, returning the existing row unchanged otherwise (spec §100
  /// "ensure..." semantics — safe to call on every daemon start).
  @discardableResult
  func ensureHost(id: HostID) async throws -> HostRecord

  func mode(id: HostID) async throws -> HostMode

  /// Compare-and-swap: fails with `PersistenceError.staleWrite` if the host's current mode isn't
  /// `from`, or with `StateTransitionError` if `from -> to` isn't a legal `HostMode` edge.
  func setMode(id: HostID, from: HostMode, to: HostMode) async throws
}

public final class GRDBHostRepository: HostRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func ensureHost(id: HostID) async throws -> HostRecord {
    try await db.write { db in
      if let existing = try HostRecord.fetchOne(db, key: id) {
        return existing
      }
      let now = DatabaseDate.now
      let record = HostRecord(id: id, mode: .normal, createdAt: now, updatedAt: now)
      try DatabaseErrorMapper.run(entity: "host") { try record.insert(db) }
      return record
    }
  }

  public func mode(id: HostID) async throws -> HostMode {
    try await db.read { db in
      guard let record = try HostRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "host", id: id.rawValue)
      }
      return record.mode
    }
  }

  public func setMode(id: HostID, from: HostMode, to: HostMode) async throws {
    try await db.write { db in
      guard var record = try HostRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "host", id: id.rawValue)
      }
      guard record.mode == from else {
        throw PersistenceError.staleWrite(
          entity: "host", id: id.rawValue, expectedState: from.rawValue, actualState: record.mode.rawValue
        )
      }
      record.mode = try from.transitioned(to: to)
      record.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "host") { try record.update(db) }
    }
  }
}
