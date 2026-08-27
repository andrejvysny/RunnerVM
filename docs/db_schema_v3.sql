-- RunnerVM SQLite schema v3: restart-recovery bookkeeping for orphaned image builds.
-- Delta over v2 only. `ADD COLUMN` does not re-validate the `state` CHECK constraint, so this is
-- safe to apply to any existing v2 database.
--
-- `recovery_since` is the instant recovery first found this build's builder worker alive-or-
-- unverifiable. NULL means "not pending": either the build is owned by a live task, or its worker
-- was proven dead. It is what bounds how long a build nobody can prove dead keeps its host
-- capacity, its base-image pin and its directory.
ALTER TABLE image_builds ADD COLUMN recovery_since TEXT;
