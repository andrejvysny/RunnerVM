import Foundation
import GRDB
import RunnerCore

/// Owns the single GRDB connection pool onto the orchestrator's SQLite database. Only `runnerd`
/// opens this type (spec §44 "the CLI never directly opens it") — `runnerctl` talks to `runnerd`
/// over RPC instead.
public final class RunnerDatabase: Sendable {
  let pool: DatabasePool

  /// Set only for `inMemory()` databases: the backing file (plus its `-wal`/`-shm` siblings) is
  /// removed when the last reference to this instance goes away.
  private let temporaryFileURL: URL?

  private init(pool: DatabasePool, temporaryFileURL: URL?) {
    self.pool = pool
    self.temporaryFileURL = temporaryFileURL
  }

  deinit {
    guard let temporaryFileURL else { return }
    try? pool.close()
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? fm.removeItem(at: URL(fileURLWithPath: temporaryFileURL.path + suffix))
    }
  }

  /// Opens (creating if absent) the database at `url`, applying every pending migration.
  public static func open(at url: URL) throws -> RunnerDatabase {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: url.path, configuration: configuration())
    try Migrator.migrate(pool)
    return RunnerDatabase(pool: pool, temporaryFileURL: nil)
  }

  /// A private, fully-migrated database backed by a throwaway file (tests only). `DatabasePool`
  /// requires a real file for WAL mode, so this is a temp path under
  /// `FileManager.default.temporaryDirectory`, deleted on deinit rather than a true in-memory
  /// connection.
  public static func inMemory() throws -> RunnerDatabase {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-test-\(UUID().uuidString).sqlite")
    let pool = try DatabasePool(path: file.path, configuration: configuration())
    try Migrator.migrate(pool)
    return RunnerDatabase(pool: pool, temporaryFileURL: file)
  }

  private static func configuration() -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.journalMode = .wal
    // sqlite3_busy_timeout(5000) — spec §44.
    config.busyMode = .timeout(5)
    return config
  }

  public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    try await pool.read(block)
  }

  /// Wraps `block` in a single transaction (GRDB's `DatabaseWriter.write`), so every repository
  /// CAS transition below only needs its own `db.write { ... }` call to be atomic.
  public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    try await pool.write(block)
  }
}
