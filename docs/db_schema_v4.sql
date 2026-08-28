-- RunnerVM SQLite schema v4: managed images, maintenance instances, macOS provisioning builds.
--
-- managed_images: one row per auto-updating image (a registry tag or a Tart macOS image),
--   tracking it through check -> download/build -> qualify -> promote independently of any single
--   image_builds row.
-- instances.purpose: 'maintenance' marks an instance created to qualify a candidate image rather
--   than run a job, so the scheduler and demand accounting can exclude it.
-- instances.pinned_until: keeps a maintenance instance alive past its normal idle/retire policy
--   while a candidate image is still being qualified.
-- image_builds.kind: 'macosProvision' distinguishes a macOS guest-provisioning build from an
--   ordinary Runnerfile build.
-- image_builds.managed_name: links a build back to the managed_images row that triggered it.
-- image_builds.source_digest: the upstream digest (the registry tag's or Tart image's digest)
--   this build is qualifying -- distinct from base_digest (the FROM base) and image_digest (the
--   build's own output).
--
-- Deliberately no FK from managed_images' digest columns to images(digest): rollback and
-- retention churn on either table must not be ordering-constrained by the other -- cf. the v1
-- instances.image_digest FK tombstone bug (TODO.md M2 finding (c)).
CREATE TABLE managed_images (
  name TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('registryTag','macosTart')),
  source_reference TEXT NOT NULL,
  last_source_digest TEXT,
  current_image_digest TEXT,
  candidate_image_digest TEXT,
  previous_digests_json TEXT NOT NULL DEFAULT '[]',
  state TEXT NOT NULL DEFAULT 'idle'
    CHECK (state IN ('idle','checking','downloading','building','qualifying','promoting','failed')),
  last_checked_at TEXT,
  last_updated_at TEXT,
  last_error TEXT,
  auto_update INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL);
ALTER TABLE instances ADD COLUMN purpose TEXT NOT NULL DEFAULT 'runner';
ALTER TABLE instances ADD COLUMN pinned_until TEXT;
ALTER TABLE image_builds ADD COLUMN kind TEXT NOT NULL DEFAULT 'runnerfile';
ALTER TABLE image_builds ADD COLUMN managed_name TEXT;
ALTER TABLE image_builds ADD COLUMN source_digest TEXT;
