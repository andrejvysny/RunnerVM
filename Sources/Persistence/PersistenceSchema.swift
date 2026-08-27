/// Single source of truth for the highest SQLite schema version this build understands.
///
/// `Migrator.currentSchemaVersion` reads this, and `Orchestration.RunnerVMBuild.schemaVersion`
/// mirrors it for `system.version`/`system.status`. The "v1" migration itself inserts the literal
/// `1` rather than this constant -- see the comment on that migration for why.
public enum PersistenceSchema {
  public static let currentVersion = 2
}
