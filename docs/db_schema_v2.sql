-- RunnerVM SQLite schema v2: in-daemon image builds and mutable image names.
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
-- A mutable, unique local name → immutable digest. The name inside an image's manifest.json never
-- moves; this table is what `FROM name` and `--profile image: name` resolve through after a rebuild.
CREATE TABLE image_aliases (
  name TEXT PRIMARY KEY,
  digest TEXT NOT NULL REFERENCES images(digest),
  updated_at TEXT NOT NULL);
