import RunnerCore
import Testing
@testable import Persistence

@Suite struct HostRepositoryTests {
  @Test func ensureHostIsIdempotent() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)
    let first = try await repo.ensureHost(id: Fixtures.hostID)
    let second = try await repo.ensureHost(id: Fixtures.hostID)
    // Not a full `==`: `first` is the in-memory value from the initial insert (full `Date`
    // precision), while `second` is re-fetched from storage — `DatabaseDate`'s ISO-8601 TEXT
    // round-trip only preserves millisecond precision, so the two `createdAt` values can differ
    // at the sub-millisecond level even though they represent "the same" ensure-then-ensure call.
    #expect(first.id == second.id)
    #expect(first.mode == second.mode)
    #expect(first.mode == .normal)
  }

  @Test func setModeHappyPath() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)
    try await repo.ensureHost(id: Fixtures.hostID)

    try await repo.setMode(id: Fixtures.hostID, from: .normal, to: .draining)
    #expect(try await repo.mode(id: Fixtures.hostID) == .draining)

    try await repo.setMode(id: Fixtures.hostID, from: .draining, to: .offline)
    #expect(try await repo.mode(id: Fixtures.hostID) == .offline)
  }

  @Test func setModeRejectsWrongCurrentState() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)
    try await repo.ensureHost(id: Fixtures.hostID)

    await #expect(throws: PersistenceError.self) {
      try await repo.setMode(id: Fixtures.hostID, from: .draining, to: .offline)
    }
    // Mode is unchanged after the rejected CAS.
    #expect(try await repo.mode(id: Fixtures.hostID) == .normal)
  }

  @Test func setModeRejectsIllegalEdge() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)
    try await repo.ensureHost(id: Fixtures.hostID)

    await #expect(throws: StateTransitionError.self) {
      try await repo.setMode(id: Fixtures.hostID, from: .normal, to: .offline)
    }
  }

  @Test func modeOnUnknownHostThrowsNotFound() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBHostRepository(db: db)
    await #expect(throws: PersistenceError.self) {
      _ = try await repo.mode(id: HostID(rawValue: "does-not-exist"))
    }
  }
}
