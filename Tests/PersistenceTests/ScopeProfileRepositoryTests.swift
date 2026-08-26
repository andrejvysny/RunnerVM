import RunnerCore
import Testing
@testable import Persistence

@Suite struct ScopeRepositoryTests {
  @Test func upsertInsertsThenUpdatesByName() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBScopeRepository(db: db)

    let first = Fixtures.scope(name: "acme")
    try await repo.upsert(first)
    let inserted = try #require(try await repo.get(name: "acme"))
    #expect(inserted.owner == "acme")

    var updated = first
    updated.id = GitHubScopeID.generate() // caller-supplied id must not matter for an update-by-name
    updated.owner = "acme-renamed"
    try await repo.upsert(updated)

    let fetched = try #require(try await repo.get(name: "acme"))
    #expect(fetched.id == inserted.id, "upsert must keep the original row's id")
    #expect(fetched.owner == "acme-renamed")
    #expect(fetched.createdAt == inserted.createdAt, "upsert must keep the original createdAt")

    let all = try await repo.list()
    #expect(all.count == 1)
  }

  @Test func deleteReferencedScopeFails() async throws {
    let db = try TestDatabase.make()
    let scopeRepo = GRDBScopeRepository(db: db)
    let profileRepo = GRDBProfileRepository(db: db)

    let scope = Fixtures.scope()
    try await scopeRepo.upsert(scope)
    try await profileRepo.upsert(Fixtures.profile(scopeId: scope.id))

    await #expect(throws: PersistenceError.self) {
      try await scopeRepo.delete(name: scope.name)
    }
  }

  @Test func deleteUnreferencedScopeSucceeds() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBScopeRepository(db: db)
    let scope = Fixtures.scope()
    try await repo.upsert(scope)
    try await repo.delete(name: scope.name)
    #expect(try await repo.get(name: scope.name) == nil)
  }
}

@Suite struct ProfileRepositoryTests {
  @Test func upsertInsertsThenUpdatesByName() async throws {
    let db = try TestDatabase.make()
    let scope = Fixtures.scope()
    try await GRDBScopeRepository(db: db).upsert(scope)
    let repo = GRDBProfileRepository(db: db)

    let first = Fixtures.profile(scopeId: scope.id)
    try await repo.upsert(first)
    let inserted = try #require(try await repo.get(name: first.name))

    var updated = first
    updated.id = RunnerProfileID.generate()
    updated.cpuCount = 8
    try await repo.upsert(updated)

    let fetched = try #require(try await repo.get(name: first.name))
    #expect(fetched.id == inserted.id)
    #expect(fetched.cpuCount == 8)
  }

  @Test func deleteReferencedByInstanceFails() async throws {
    let db = try TestDatabase.make()
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    try await GRDBInstanceRepository(db: db).insert(
      Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    )

    let profileRepo = GRDBProfileRepository(db: db)
    let profile = try #require(try await profileRepo.get(name: "linux-default"))

    await #expect(throws: PersistenceError.self) {
      try await profileRepo.delete(name: profile.name)
    }
  }

  @Test func insertWithUnknownProfileFailsForeignKey() async throws {
    let db = try TestDatabase.make()
    try await GRDBHostRepository(db: db).ensureHost(id: Fixtures.hostID)
    let image = Fixtures.image()
    try await GRDBImageRepository(db: db).upsert(image)

    let orphanInstance = Fixtures.instance(
      profileId: RunnerProfileID(rawValue: "no-such-profile"), imageDigest: image.digest
    )
    await #expect(throws: PersistenceError.self) {
      try await GRDBInstanceRepository(db: db).insert(orphanInstance)
    }
  }
}
