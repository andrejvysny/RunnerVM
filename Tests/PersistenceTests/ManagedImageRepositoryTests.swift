import Foundation
import RunnerCore
import Testing
@testable import Persistence

private enum ManagedImageFixtures {
  static func record(
    name: String = "ubuntu-24-runner", kind: ManagedImageKind = .registryTag,
    sourceReference: String = "ghcr.io/acme/ubuntu-24:latest", state: ManagedImageState = .idle
  ) -> ManagedImageRecord {
    ManagedImageRecord(name: name, kind: kind, sourceReference: sourceReference, state: state, updatedAt: .now)
  }
}

@Suite struct ManagedImageRepositoryTests {
  /// Same reasoning as `ImageBuildRepositoryTests.noopMutate`: hoisted out of `#expect(throws:)`
  /// call sites to keep the type checker happy with `inout` + async-throwing macro expansion.
  private static let noopMutate: @Sendable (inout ManagedImageRecord) -> Void = { _ in }

  @Test func upsertInsertsThenGetReturnsIt() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    let record = ManagedImageFixtures.record()
    try await repo.upsert(record)

    let fetched = try #require(try await repo.get(name: record.name))
    #expect(fetched.kind == .registryTag)
    #expect(fetched.sourceReference == "ghcr.io/acme/ubuntu-24:latest")
    #expect(fetched.state == .idle)
    #expect(fetched.autoUpdate == true)
    #expect(fetched.previousDigestsJson == "[]")
  }

  @Test func upsertUpdatesAnExistingRowByName() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    var record = ManagedImageFixtures.record()
    try await repo.upsert(record)

    record.sourceReference = "ghcr.io/acme/ubuntu-24:24.04"
    record.lastSourceDigest = "sha256:" + String(repeating: "a", count: 64)
    try await repo.upsert(record)

    #expect(try await repo.list().count == 1)
    let fetched = try #require(try await repo.get(name: record.name))
    #expect(fetched.sourceReference == "ghcr.io/acme/ubuntu-24:24.04")
    #expect(fetched.lastSourceDigest == record.lastSourceDigest)
  }

  @Test func listReturnsEveryRow() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    try await repo.upsert(ManagedImageFixtures.record(name: "a"))
    try await repo.upsert(ManagedImageFixtures.record(name: "b", kind: .macosTart))

    let all = try await repo.list()
    #expect(Set(all.map(\.name)) == ["a", "b"])
  }

  @Test func listFiltersByKind() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    try await repo.upsert(ManagedImageFixtures.record(name: "registry-one", kind: .registryTag))
    try await repo.upsert(ManagedImageFixtures.record(
      name: "tart-one", kind: .macosTart, sourceReference: "tart://sequoia-base"))

    let tarts = try await repo.list(kind: .macosTart)
    #expect(tarts.map(\.name) == ["tart-one"])
  }

  @Test func deleteRemovesTheRow() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    let record = ManagedImageFixtures.record()
    try await repo.upsert(record)

    try await repo.delete(name: record.name)

    #expect(try await repo.get(name: record.name) == nil)
  }

  @Test func previousDigestsJsonRoundTripsThroughTheCodecHelpers() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    let digests = [
      ImageDigest(rawValue: "sha256:" + String(repeating: "1", count: 64)),
      ImageDigest(rawValue: "sha256:" + String(repeating: "2", count: 64)),
    ]
    var record = ManagedImageFixtures.record()
    record.previousDigestsJson = try ManagedImageRecord.encodePreviousDigests(digests)
    try await repo.upsert(record)

    let fetched = try #require(try await repo.get(name: record.name))
    #expect(try fetched.decodedPreviousDigests() == digests)
  }

  @Test func transitionHappyPathUpdatesStateAndStampsUpdatedAt() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    var record = ManagedImageFixtures.record()
    record.updatedAt = DatabaseDate(Date(timeIntervalSince1970: 1_000))
    try await repo.upsert(record)

    let updated = try await repo.transition(name: record.name, from: .idle, to: .checking) {
      $0.lastCheckedAt = .now
    }

    #expect(updated.state == .checking)
    #expect(updated.lastCheckedAt != nil)
    #expect(updated.updatedAt > record.updatedAt)
    let refetched = try #require(try await repo.get(name: record.name))
    #expect(refetched.state == .checking)
  }

  @Test func transitionRejectsWrongCurrentState() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    let record = ManagedImageFixtures.record() // state == .idle
    try await repo.upsert(record)

    await #expect(throws: PersistenceError.self) {
      _ = try await repo.transition(name: record.name, from: .checking, to: .idle, mutate: Self.noopMutate)
    }
  }

  @Test func transitionRejectsIllegalEdge() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)
    let record = ManagedImageFixtures.record() // state == .idle
    try await repo.upsert(record)

    await #expect(throws: StateTransitionError.self) {
      _ = try await repo.transition(name: record.name, from: .idle, to: .qualifying, mutate: Self.noopMutate)
    }
  }

  @Test func transitionOnMissingRowThrowsNotFound() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBManagedImageRepository(db: db)

    await #expect(throws: PersistenceError.self) {
      _ = try await repo.transition(name: "does-not-exist", from: .idle, to: .checking, mutate: Self.noopMutate)
    }
  }

  @Test func bogusKindIsRejectedByTheCheckConstraint() async throws {
    let db = try TestDatabase.make()
    await #expect(throws: (any Error).self) {
      try await db.write { db in
        try db.execute(
          sql: """
          INSERT INTO managed_images (name, kind, source_reference, state, updated_at)
          VALUES ('bad', 'bogus', 'ghcr.io/acme/x:latest', 'idle', ?)
          """,
          arguments: [DatabaseDate.now]
        )
      }
    }
  }

  @Test func bogusStateIsRejectedByTheCheckConstraint() async throws {
    let db = try TestDatabase.make()
    await #expect(throws: (any Error).self) {
      try await db.write { db in
        try db.execute(
          sql: """
          INSERT INTO managed_images (name, kind, source_reference, state, updated_at)
          VALUES ('bad', 'registryTag', 'ghcr.io/acme/x:latest', 'bogus', ?)
          """,
          arguments: [DatabaseDate.now]
        )
      }
    }
  }
}
