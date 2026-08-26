import RunnerCore
import Testing
@testable import Persistence

/// End-to-end sanity check across the whole module: open a database, migrate it, and round-trip
/// one row through a repository. The individual suites (`MigrationTests`, `*RepositoryTests`)
/// cover the details.
@Suite struct PersistenceSmoke {
  @Test func opensMigratesAndRoundTripsARecord() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)

    let host = try await repo.ensureHost(id: Fixtures.hostID)
    #expect(host.mode == .normal)
    #expect(try await repo.mode(id: Fixtures.hostID) == .normal)
  }
}
