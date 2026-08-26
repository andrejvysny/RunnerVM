import GRDB
import RunnerCore

public protocol ProfileRepository: Sendable {
  /// Inserts a new profile, or updates the row already registered under `profile.name` — mirrors
  /// `ScopeRepository.upsert` (identity is the unique `name`).
  func upsert(_ profile: RunnerProfileRecord) async throws
  func get(name: String) async throws -> RunnerProfileRecord?
  func list() async throws -> [RunnerProfileRecord]
  /// Fails via `PersistenceError.foreignKeyViolated` if any `instances`, `scale_sets`, or
  /// `runner_sessions` row still references this profile.
  func delete(name: String) async throws
}

public final class GRDBProfileRepository: ProfileRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func upsert(_ profile: RunnerProfileRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "runner_profiles") {
        if let existing = try RunnerProfileRecord
          .filter(Column("name") == profile.name)
          .fetchOne(db)
        {
          var updated = profile
          updated.id = existing.id
          updated.createdAt = existing.createdAt
          updated.updatedAt = .now
          try updated.update(db)
        } else {
          var toInsert = profile
          toInsert.updatedAt = toInsert.createdAt
          try toInsert.insert(db)
        }
      }
    }
  }

  public func get(name: String) async throws -> RunnerProfileRecord? {
    try await db.read { db in
      try RunnerProfileRecord.filter(Column("name") == name).fetchOne(db)
    }
  }

  public func list() async throws -> [RunnerProfileRecord] {
    try await db.read { db in try RunnerProfileRecord.fetchAll(db) }
  }

  public func delete(name: String) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "runner_profiles") {
        _ = try RunnerProfileRecord.filter(Column("name") == name).deleteAll(db)
      }
    }
  }
}
