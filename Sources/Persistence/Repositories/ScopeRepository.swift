import GRDB
import RunnerCore

public protocol ScopeRepository: Sendable {
  /// Inserts a new scope, or updates the row already registered under `scope.name` — identity is
  /// the unique `name`, not `scope.id` (config reconciliation reapplies the same name repeatedly).
  func upsert(_ scope: GitHubScopeRecord) async throws
  func get(name: String) async throws -> GitHubScopeRecord?
  func list() async throws -> [GitHubScopeRecord]
  /// Fails via `PersistenceError.foreignKeyViolated` if a `runner_profiles` row still references
  /// this scope (`runner_profiles.scope_id REFERENCES github_scopes(id)`, no `ON DELETE CASCADE`).
  func delete(name: String) async throws
}

public final class GRDBScopeRepository: ScopeRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func upsert(_ scope: GitHubScopeRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "github_scopes") {
        if let existing = try GitHubScopeRecord
          .filter(Column("name") == scope.name)
          .fetchOne(db)
        {
          var updated = scope
          updated.id = existing.id
          updated.createdAt = existing.createdAt
          updated.updatedAt = .now
          try updated.update(db)
        } else {
          var toInsert = scope
          toInsert.updatedAt = toInsert.createdAt
          try toInsert.insert(db)
        }
      }
    }
  }

  public func get(name: String) async throws -> GitHubScopeRecord? {
    try await db.read { db in
      try GitHubScopeRecord.filter(Column("name") == name).fetchOne(db)
    }
  }

  public func list() async throws -> [GitHubScopeRecord] {
    try await db.read { db in try GitHubScopeRecord.fetchAll(db) }
  }

  public func delete(name: String) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "github_scopes") {
        _ = try GitHubScopeRecord.filter(Column("name") == name).deleteAll(db)
      }
    }
  }
}
