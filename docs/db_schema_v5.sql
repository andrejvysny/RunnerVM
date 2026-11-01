-- RunnerVM SQLite schema v5: runner profiles gain a provider; GitLab profiles have no GitHub scope.
--
-- runner_profiles.provider: 'github' (every pre-v5 row) or 'gitlab'. GitLab profiles only supply
--   VMs when gitlab-runner asks for them, so they have no scope_id and are invisible to scale-set,
--   JIT and scope-health code.
-- runner_profiles.scope_id: now nullable; the table CHECK pins NULL to gitlab and NOT NULL to
--   github so a profile can never be half of each.
--
-- SQLite cannot relax NOT NULL in place, so the table is rebuilt: create the new table, copy,
-- DROP the old one, then rename the NEW one into place. The old table is never renamed: with
-- SQLite >= 3.26 that would rewrite the REFERENCES runner_profiles(id) clauses of scale_sets,
-- instances and runner_sessions to point at the renamed (then dropped) table. GRDB's migrator runs
-- with foreign keys off and runs foreign_key_check afterwards, so the DROP does not cascade.
-- runner_profiles had no indexes or triggers beyond the UNIQUE(name) in its definition (v1-v4).
CREATE TABLE runner_profiles_v5 (
  id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL, scope_id TEXT REFERENCES github_scopes(id),
  provider TEXT NOT NULL DEFAULT 'github' CHECK (provider IN ('github','gitlab')),
  image_reference TEXT NOT NULL, guest_os TEXT NOT NULL CHECK (guest_os IN ('linux','macos')),
  lifecycle TEXT NOT NULL CHECK (lifecycle IN ('ephemeral','reusable')),
  cpu_count INTEGER NOT NULL, memory_bytes INTEGER NOT NULL, disk_bytes INTEGER NOT NULL,
  min_idle INTEGER NOT NULL DEFAULT 0, max_idle INTEGER NOT NULL DEFAULT 0, max_instances INTEGER,
  ssh_enabled INTEGER NOT NULL DEFAULT 1, config_json TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK ((provider = 'gitlab' AND scope_id IS NULL) OR (provider = 'github' AND scope_id IS NOT NULL)));
INSERT INTO runner_profiles_v5 (
  id, name, scope_id, provider, image_reference, guest_os, lifecycle, cpu_count, memory_bytes,
  disk_bytes, min_idle, max_idle, max_instances, ssh_enabled, config_json, enabled, created_at,
  updated_at)
SELECT
  id, name, scope_id, 'github', image_reference, guest_os, lifecycle, cpu_count, memory_bytes,
  disk_bytes, min_idle, max_idle, max_instances, ssh_enabled, config_json, enabled, created_at,
  updated_at
FROM runner_profiles;
DROP TABLE runner_profiles;
ALTER TABLE runner_profiles_v5 RENAME TO runner_profiles;
