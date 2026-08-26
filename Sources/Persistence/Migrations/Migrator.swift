import Foundation
import GRDB
import RunnerCore

/// Forward-only schema migrations (spec §44 "use explicit schema migrations"). Erasing on schema
/// drift would silently destroy durable orchestrator state, so `eraseDatabaseOnSchemaChange`
/// stays `false` — a shape change ships as a new migration, never a wipe.
enum Migrator {
  /// The highest schema version this build understands. `migrate` refuses to open a database a
  /// newer build already migrated further than this.
  static let currentSchemaVersion = 1

  static func migrate(_ writer: any DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.eraseDatabaseOnSchemaChange = false

    migrator.registerMigration("v1") { db in
      try db.execute(sql: schemaV1SQL)
      // `schema_migrations` is created by the statements above; GRDB's own bookkeeping table
      // (`grdb_migrations`) is what makes this closure run exactly once, so this insert happens
      // only on the very first `open`/`inMemory` call against a given database file.
      try db.execute(
        sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        arguments: [currentSchemaVersion, DatabaseDate.now]
      )
    }

    do {
      try migrator.migrate(writer)
    } catch let error as PersistenceError {
      throw error
    } catch {
      throw PersistenceError.migrationFailed(version: currentSchemaVersion, reason: String(describing: error))
    }

    try writer.write { db in
      let maxVersion = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations") ?? 0
      guard maxVersion <= currentSchemaVersion else {
        throw PersistenceError.schemaVersionUnsupported(found: maxVersion, supported: currentSchemaVersion)
      }
    }
  }

  /// Verbatim contents of `docs/db_schema_v1.sql` (spec §45), the single source of truth for
  /// table/column/index names. GRDB's `Database.execute(sql:)` splits and runs each
  /// `;`-terminated statement in a string, so this is embedded whole rather than re-typed
  /// statement-by-statement, eliminating any chance of a transcription drift from the file.
  private static let schemaV1SQL = """
    -- RunnerVM SQLite schema v1 (spec §45 + plan C1). Only runnerd opens this database.
    -- PRAGMA journal_mode=WAL; foreign_keys=ON; busy_timeout=5000.
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
    -- NEVER add a jit_config column (spec §45).
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
}
