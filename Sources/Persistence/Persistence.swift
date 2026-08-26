// Persistence — see plan Part C0 for module responsibility. GRDB-backed SQLite store: migrations
// (`Migrations/`), Codable table mirrors (`Records/`), and repository protocols + GRDB
// implementations (`Repositories/`) built on `RunnerDatabase` (`Database.swift`).
public enum PersistenceModule {
  public static let name = "Persistence"
}
