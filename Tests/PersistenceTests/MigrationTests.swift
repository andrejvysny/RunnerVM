import Foundation
import Testing
@testable import Persistence

@Suite struct MigrationTests {
  private static let expectedTables: Set<String> = [
    "host", "github_scopes", "runner_profiles", "scale_sets", "scale_set_sessions",
    "scale_set_inbox", "images", "image_pins", "instances", "runner_sessions", "operations",
    "job_summaries", "audit_events",
  ]

  @Test func createsAllThirteenTablesAndTheSchemaMigrationsRow() async throws {
    let db = try TestDatabase.make()
    let tableNames = try await db.read { db in
      try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for table in Self.expectedTables {
      #expect(tableNames.contains(table), "missing table \(table)")
    }

    let versions = try await db.read { db in
      try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
    }
    #expect(versions == [1])
  }

  @Test func pragmasAreSet() async throws {
    let db = try TestDatabase.make()
    let (journalMode, foreignKeys) = try await db.read { db in
      let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
      let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
      return (journalMode, foreignKeys)
    }
    #expect(journalMode.lowercased() == "wal")
    #expect(foreignKeys == 1)
  }

  @Test func jitConfigColumnDoesNotExistOnRunnerSessions() async throws {
    let db = try TestDatabase.make()
    let columns = try await db.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('runner_sessions')")
    }
    #expect(!columns.contains("jit_config"))
  }

  @Test func secondOpenAtTheSamePathIsIdempotent() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-migration-idempotency-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + suffix))
      }
    }

    _ = try RunnerDatabase.open(at: path)
    let second = try RunnerDatabase.open(at: path)

    let versions = try await second.read { db in
      try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
    }
    #expect(versions == [1])
  }
}
