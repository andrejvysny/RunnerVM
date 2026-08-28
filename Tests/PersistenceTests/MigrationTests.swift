import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite struct MigrationTests {
  private static let expectedTables: Set<String> = [
    "host", "github_scopes", "runner_profiles", "scale_sets", "scale_set_sessions",
    "scale_set_inbox", "images", "image_pins", "instances", "runner_sessions", "operations",
    "job_summaries", "audit_events", "image_builds", "image_aliases", "managed_images",
  ]

  @Test func createsEveryTableAndTheSchemaMigrationsRows() async throws {
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
    #expect(versions == [1, 2, 3, 4])
  }

  /// `PersistenceSchema.currentVersion` is the source of truth `Migrator` and
  /// `Orchestration.RunnerVMBuild.schemaVersion` both read; the "v1"/"v2"/"v3"/"v4" migrations
  /// themselves insert the literal `1`/`2`/`3`/`4` so a later bump to `currentVersion` cannot make
  /// a fresh database's existing migrations record the wrong version (see the comment on each
  /// migration).
  @Test func recordedVersionsMatchPersistenceSchemaExactly() async throws {
    let db = try TestDatabase.make()
    let versions = try await db.read { db in
      try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
    }
    #expect(versions == [1, 2, 3, 4])
    #expect(versions.last == PersistenceSchema.currentVersion)
  }

  /// A database created before v2 existed (only the v1 SQL, with the v1 migration's literal row)
  /// upgrades cleanly to the current schema on next open, preserving the v1 rows it had.
  @Test func upgradesAV1OnlyDatabaseToTheCurrentSchemaPreservingRows() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-migration-v1-upgrade-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + suffix))
      }
    }

    var config = GRDB.Configuration()
    config.foreignKeysEnabled = true
    let v1Pool = try DatabasePool(path: path.path, configuration: config)
    // Registered under the literal name "v1", exactly like production's `Migrator`, so GRDB's own
    // migration bookkeeping (`grdb_migrations`, distinct from our own `schema_migrations` table)
    // marks it done -- which is what makes reopening below skip straight to "v2" instead of trying
    // to redo "v1" and colliding with the tables it already created.
    var v1Migrator = DatabaseMigrator()
    v1Migrator.eraseDatabaseOnSchemaChange = false
    v1Migrator.registerMigration("v1") { db in
      try db.execute(sql: Self.v1OnlySQL)
      try db.execute(sql: "INSERT INTO host (id, mode, created_at, updated_at) VALUES (?, ?, ?, ?)",
                     arguments: ["test-host", "normal", DatabaseDate.now, DatabaseDate.now])
      try db.execute(
        sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        arguments: [1, DatabaseDate.now]
      )
    }
    try v1Migrator.migrate(v1Pool)
    try v1Pool.close()

    let upgraded = try RunnerDatabase.open(at: path)
    let (versions, hosts, tableNames) = try await upgraded.read { db in
      (
        try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version"),
        try String.fetchAll(db, sql: "SELECT id FROM host"),
        try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
      )
    }
    #expect(versions == [1, 2, 3, 4])
    #expect(hosts == ["test-host"])
    #expect(tableNames.contains("image_builds"))
    #expect(tableNames.contains("image_aliases"))
  }

  /// A database a pre-v3 build left at v2 upgrades in place, all the way through v4: `ALTER TABLE
  /// ... ADD COLUMN` keeps every `image_builds` row it already had, the v3 `recovery_since` reads
  /// back NULL ("not pending recovery"), and the v4 `kind` reads back its `DEFAULT 'runnerfile'`
  /// for a row that predates the column entirely.
  @Test func upgradesAV2DatabaseToTheCurrentSchemaPreservingImageBuildRows() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-migration-v2-upgrade-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + suffix))
      }
    }

    var config = GRDB.Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: path.path, configuration: config)
    try Self.migrateToV2(pool)
    try pool.close()

    let upgraded = try RunnerDatabase.open(at: path)
    let (versions, builds, notPending, columns, kind) = try await upgraded.read { db in
      (
        try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version"),
        try String.fetchAll(db, sql: "SELECT id FROM image_builds"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_builds WHERE recovery_since IS NULL"),
        try String.fetchSet(db, sql: "SELECT name FROM pragma_table_info('image_builds')"),
        try String.fetchOne(db, sql: "SELECT kind FROM image_builds WHERE id = 'build-from-v2'")
      )
    }
    #expect(versions == [1, 2, 3, 4])
    #expect(builds == ["build-from-v2"])
    #expect(columns.contains("recovery_since"))
    #expect(columns.contains("kind"))
    #expect(columns.contains("managed_name"))
    #expect(columns.contains("source_digest"))
    #expect(notPending == 1)
    #expect(kind == "runnerfile")
  }

  /// Runs "v1" and "v2" under production's own migration names, so reopening the file with
  /// `RunnerDatabase.open` runs only "v3" -- the shape a real pre-v3 daemon left behind.
  private static func migrateToV2(_ pool: DatabasePool) throws {
    var migrator = DatabaseMigrator()
    migrator.eraseDatabaseOnSchemaChange = false
    migrator.registerMigration("v1") { db in
      try db.execute(sql: v1OnlySQL)
      try db.execute(sql: "INSERT INTO host (id, mode, created_at, updated_at) VALUES (?, ?, ?, ?)",
                     arguments: ["test-host", "normal", DatabaseDate.now, DatabaseDate.now])
      try db.execute(
        sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        arguments: [1, DatabaseDate.now])
    }
    migrator.registerMigration("v2") { db in
      try db.execute(sql: v2OnlySQL)
      try db.execute(sql: insertV2BuildSQL, arguments: ["build-from-v2", "test-host", "provisioning"])
      try db.execute(
        sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        arguments: [2, DatabaseDate.now])
    }
    try migrator.migrate(pool)
  }

  /// Every `NOT NULL` column v2's `image_builds` declares, and nothing v3 adds.
  private static let insertV2BuildSQL = """
    INSERT INTO image_builds (
      id, host_id, state, recipe_path, recipe_sha256, context_path, args_json, from_kind,
      from_reference, cpu_count, memory_bytes, disk_bytes, disk_reservation_bytes, timeout_ms,
      build_path, log_path, total_steps, current_step, created_at, updated_at)
    VALUES (?, ?, ?, '/tmp/Runnerfile', 'sha256:0', '/tmp', '{}', 'image', 'test-linux',
      2, 1073741824, 67108864, 67108864, 60000, '/tmp/build', '/tmp/build.log', 0, 0,
      datetime('now'), datetime('now'))
    """

  /// Verbatim `docs/db_schema_v2.sql`, duplicated for the same reason `v1OnlySQL` is: this test
  /// must exercise what an *actual* pre-v3 database file looked like.
  private static let v2OnlySQL = """
    CREATE TABLE image_builds (
      id TEXT PRIMARY KEY,
      host_id TEXT NOT NULL REFERENCES host(id),
      name TEXT,
      state TEXT NOT NULL CHECK (state IN ('queued','resolving','staging','booting','provisioning','sealing','succeeded','failed','cancelled')),
      operation_id TEXT REFERENCES operations(id),
      push_reference TEXT,
      push_operation_id TEXT REFERENCES operations(id),
      recipe_path TEXT NOT NULL,
      recipe_sha256 TEXT NOT NULL,
      context_path TEXT NOT NULL,
      context_sha256 TEXT,
      args_json TEXT NOT NULL DEFAULT '{}',
      from_kind TEXT NOT NULL CHECK (from_kind IN ('image','cloudImage','registry')),
      from_reference TEXT NOT NULL,
      base_digest TEXT,
      base_sha256 TEXT,
      cpu_count INTEGER NOT NULL,
      memory_bytes INTEGER NOT NULL,
      disk_bytes INTEGER NOT NULL,
      disk_reservation_bytes INTEGER NOT NULL,
      timeout_ms INTEGER NOT NULL,
      build_path TEXT NOT NULL,
      log_path TEXT NOT NULL,
      worker_pid INTEGER,
      worker_nonce TEXT,
      total_steps INTEGER NOT NULL DEFAULT 0,
      current_step INTEGER NOT NULL DEFAULT 0,
      current_instruction TEXT,
      image_digest TEXT,
      failure_code TEXT,
      failure_message TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      updated_at TEXT NOT NULL);
    CREATE INDEX image_builds_state ON image_builds(state);
    CREATE INDEX image_builds_created ON image_builds(created_at);
    CREATE TABLE image_aliases (
      name TEXT PRIMARY KEY,
      digest TEXT NOT NULL REFERENCES images(digest),
      updated_at TEXT NOT NULL);
    """

  /// Verbatim `docs/db_schema_v1.sql`, duplicated here (rather than reused from `Migrator`) so this
  /// test exercises what an *actual* pre-v2 database file looked like, independent of whatever the
  /// current build's private `schemaV1SQL` constant says.
  private static let v1OnlySQL = """
    CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
    CREATE TABLE host (
      id TEXT PRIMARY KEY, mode TEXT NOT NULL CHECK (mode IN ('normal','draining','offline')),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE github_scopes (
      id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('organization','repository')),
      owner TEXT NOT NULL, repository TEXT, runner_group_id INTEGER, runner_group_name TEXT,
      is_public_repository INTEGER, enabled INTEGER NOT NULL DEFAULT 1,
      health TEXT NOT NULL DEFAULT 'unknown', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE runner_profiles (
      id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, scope_id TEXT NOT NULL REFERENCES github_scopes(id),
      image_reference TEXT NOT NULL, guest_os TEXT NOT NULL CHECK (guest_os IN ('linux','macos')),
      lifecycle TEXT NOT NULL CHECK (lifecycle IN ('ephemeral','reusable')),
      cpu_count INTEGER NOT NULL, memory_bytes INTEGER NOT NULL, disk_bytes INTEGER NOT NULL,
      min_idle INTEGER NOT NULL DEFAULT 0, max_idle INTEGER NOT NULL DEFAULT 0, max_instances INTEGER,
      ssh_enabled INTEGER NOT NULL DEFAULT 1, config_json TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE scale_sets (
      id TEXT PRIMARY KEY, profile_id TEXT UNIQUE NOT NULL REFERENCES runner_profiles(id),
      github_scale_set_id INTEGER, github_scale_set_name TEXT NOT NULL,
      state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE scale_set_sessions (
      scale_set_id TEXT NOT NULL REFERENCES scale_sets(id), session_generation INTEGER NOT NULL,
      session_id TEXT, last_message_id INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY (scale_set_id, session_generation));
    CREATE TABLE scale_set_inbox (
      scale_set_id TEXT NOT NULL REFERENCES scale_sets(id), session_generation INTEGER NOT NULL,
      message_id INTEGER NOT NULL, message_type TEXT NOT NULL, body_json TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('intent','processed','deleted')),
      received_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY (scale_set_id, session_generation, message_id));
    CREATE TABLE images (
      digest TEXT PRIMARY KEY, canonical_reference TEXT, os TEXT NOT NULL, architecture TEXT NOT NULL,
      schema_version INTEGER NOT NULL, metadata_json TEXT NOT NULL, local_path TEXT NOT NULL,
      virtual_size_bytes INTEGER NOT NULL, allocated_size_bytes INTEGER,
      runner_version TEXT, guest_agent_version TEXT,
      state TEXT NOT NULL CHECK (state IN ('pulling','ready','invalid','deleting')),
      created_at TEXT NOT NULL, pulled_at TEXT, last_used_at TEXT);
    CREATE TABLE image_pins (
      owner_type TEXT NOT NULL, owner_id TEXT NOT NULL, digest TEXT NOT NULL REFERENCES images(digest),
      created_at TEXT NOT NULL, PRIMARY KEY (owner_type, owner_id, digest));
    CREATE INDEX image_pins_digest ON image_pins(digest);
    CREATE TABLE instances (
      id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES runner_profiles(id),
      image_digest TEXT NOT NULL REFERENCES images(digest), host_id TEXT NOT NULL REFERENCES host(id),
      name TEXT NOT NULL, lifecycle TEXT NOT NULL, state TEXT NOT NULL, desired_state TEXT NOT NULL,
      cpu_count INTEGER NOT NULL, memory_bytes INTEGER NOT NULL, disk_bytes INTEGER NOT NULL,
      disk_reservation_bytes INTEGER NOT NULL,
      worker_pid INTEGER, worker_generation INTEGER NOT NULL DEFAULT 0, incarnation_nonce TEXT, spec_digest TEXT,
      worker_socket TEXT, mac_address TEXT, machine_identifier TEXT, boot_id TEXT,
      tainted INTEGER NOT NULL DEFAULT 0, taint_reason TEXT, jobs_consumed INTEGER NOT NULL DEFAULT 0,
      retire_after_session INTEGER NOT NULL DEFAULT 0, hard_deadline_at TEXT,
      instance_path TEXT NOT NULL,
      created_at TEXT NOT NULL, started_at TEXT, agent_ready_at TEXT, stopped_at TEXT, deleted_at TEXT,
      last_seen_at TEXT, failure_code TEXT, failure_message TEXT);
    CREATE INDEX instances_profile_state ON instances(profile_id, state);
    CREATE TABLE runner_sessions (
      id TEXT PRIMARY KEY, instance_id TEXT NOT NULL REFERENCES instances(id),
      profile_id TEXT NOT NULL REFERENCES runner_profiles(id),
      jit_source TEXT NOT NULL CHECK (jit_source IN ('rest','scaleSet')),
      github_runner_id INTEGER, github_runner_name TEXT, github_job_request_id TEXT,
      state TEXT NOT NULL, jit_issued_at TEXT, jit_delivered_at TEXT, runner_started_at TEXT, runner_online_at TEXT,
      job_started_at TEXT, job_finished_at TEXT, result TEXT, failure_code TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX runner_sessions_instance ON runner_sessions(instance_id);
    CREATE TABLE operations (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, resource_type TEXT NOT NULL, resource_id TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('pending','running','succeeded','failed','cancelled')),
      idempotency_key TEXT UNIQUE, started_at TEXT NOT NULL, finished_at TEXT,
      error_code TEXT, error_message TEXT, metadata_json TEXT);
    CREATE TABLE job_summaries (
      id TEXT PRIMARY KEY, runner_session_id TEXT NOT NULL REFERENCES runner_sessions(id),
      peak_guest_memory_bytes INTEGER, average_guest_cpu REAL, peak_worker_rss_bytes INTEGER,
      clone_duration_ms INTEGER, boot_duration_ms INTEGER, agent_ready_duration_ms INTEGER, job_duration_ms INTEGER,
      created_at TEXT NOT NULL);
    CREATE TABLE audit_events (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, actor TEXT NOT NULL, resource_type TEXT, resource_id TEXT,
      detail_json TEXT, created_at TEXT NOT NULL);
    """

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
    #expect(versions == [1, 2, 3, 4])
  }

  /// `docs/db_schema_v4.sql`'s table and every column it adds, present on a fresh database.
  @Test func v4TableAndColumnsExistOnAFreshDatabase() async throws {
    let db = try TestDatabase.make()
    let (managedImageColumns, instanceColumns, buildColumns) = try await db.read { db in
      (
        try String.fetchSet(db, sql: "SELECT name FROM pragma_table_info('managed_images')"),
        try String.fetchSet(db, sql: "SELECT name FROM pragma_table_info('instances')"),
        try String.fetchSet(db, sql: "SELECT name FROM pragma_table_info('image_builds')")
      )
    }
    #expect(managedImageColumns == [
      "name", "kind", "source_reference", "last_source_digest", "current_image_digest",
      "candidate_image_digest", "previous_digests_json", "state", "last_checked_at",
      "last_updated_at", "last_error", "auto_update", "updated_at",
    ])
    #expect(instanceColumns.contains("purpose"))
    #expect(instanceColumns.contains("pinned_until"))
    #expect(buildColumns.contains("kind"))
    #expect(buildColumns.contains("managed_name"))
    #expect(buildColumns.contains("source_digest"))
  }

  /// Re-running `Migrator.migrate` against an already-current database is a no-op: GRDB's own
  /// `grdb_migrations` bookkeeping skips every already-applied step, so `schema_migrations` gains
  /// no duplicate rows.
  @Test func migratingAnAlreadyCurrentDatabaseIsANoOp() async throws {
    let db = try TestDatabase.make()
    try Migrator.migrate(db.pool)
    try Migrator.migrate(db.pool)

    let versions = try await db.read { db in
      try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations ORDER BY version")
    }
    #expect(versions == [1, 2, 3, 4])
  }

  /// A `schema_migrations` row past `PersistenceSchema.currentVersion` (a newer build already
  /// migrated this database further) trips the trailing guard, not GRDB's own migrator -- this
  /// build has no "v5" migration to even attempt.
  @Test func versionNewerThanSupportedIsRejected() async throws {
    let db = try TestDatabase.make()
    try await db.write { db in
      try db.execute(
        sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        arguments: [5, DatabaseDate.now]
      )
    }

    // Qualified: this file also `import GRDB`, which exports its own deprecated `PersistenceError`
    // typealias (`= RecordError`) that collides with `Persistence.PersistenceError`'s -- see
    // `Support/PersistenceErrorAlias.swift`.
    #expect(throws: Persistence.PersistenceError.self) {
      try Migrator.migrate(db.pool)
    }
  }
}
