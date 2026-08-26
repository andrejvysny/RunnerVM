import RunnerCore
import Testing
@testable import Persistence

@Suite struct ImageRepositoryTests {
  @Test func upsertThenGet() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    let image = Fixtures.image()
    try await repo.upsert(image)
    let fetched = try #require(try await repo.get(digest: image.digest))
    #expect(fetched.state == .ready)

    var updated = image
    updated.state = .invalid
    try await repo.upsert(updated)
    let refetched = try #require(try await repo.get(digest: image.digest))
    #expect(refetched.state == .invalid)
  }

  @Test func setStateHappyPath() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    var image = Fixtures.image()
    image.state = .pulling
    try await repo.upsert(image)

    try await repo.setState(digest: image.digest, from: .pulling, to: .ready)
    let fetched = try #require(try await repo.get(digest: image.digest))
    #expect(fetched.state == .ready)
  }

  @Test func setStateRejectsWrongCurrentState() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    let image = Fixtures.image() // state == .ready
    try await repo.upsert(image)

    await #expect(throws: PersistenceError.self) {
      try await repo.setState(digest: image.digest, from: .pulling, to: .ready)
    }
  }

  @Test func setStateRejectsIllegalEdge() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    let image = Fixtures.image() // state == .ready
    try await repo.upsert(image)

    await #expect(throws: PersistenceError.self) {
      try await repo.setState(digest: image.digest, from: .ready, to: .pulling)
    }
  }

  @Test func listFiltersByState() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    var pulling = Fixtures.image(digest: "sha256:\(String(repeating: "b", count: 64))")
    pulling.state = .pulling
    try await repo.upsert(Fixtures.image())
    try await repo.upsert(pulling)

    let ready = try await repo.list(state: .ready)
    #expect(ready.map(\.digest.rawValue) == [Fixtures.image().digest.rawValue])
    #expect(try await repo.list(state: nil).count == 2)
  }

  @Test func pinUnpinAreIdempotentAndCounted() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    let image = Fixtures.image()
    try await repo.upsert(image)

    try await repo.pin(ownerType: .profile, ownerId: "profile-1", digest: image.digest)
    try await repo.pin(ownerType: .profile, ownerId: "profile-1", digest: image.digest) // no-op
    #expect(try await repo.pinCount(digest: image.digest) == 1)

    try await repo.pin(ownerType: .instance, ownerId: "instance-1", digest: image.digest)
    #expect(try await repo.pinCount(digest: image.digest) == 2)

    try await repo.unpin(ownerType: .profile, ownerId: "profile-1", digest: image.digest)
    try await repo.unpin(ownerType: .profile, ownerId: "profile-1", digest: image.digest) // no-op
    #expect(try await repo.pinCount(digest: image.digest) == 1)
  }

  @Test func unpinnedImagesExcludesPinnedOnes() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    let pinned = Fixtures.image()
    let unpinned = Fixtures.image(digest: "sha256:\(String(repeating: "c", count: 64))")
    try await repo.upsert(pinned)
    try await repo.upsert(unpinned)
    try await repo.pin(ownerType: .profile, ownerId: "profile-1", digest: pinned.digest)

    let result = try await repo.unpinnedImages()
    #expect(result.map(\.digest.rawValue) == [unpinned.digest.rawValue])
  }

  @Test func pinUnknownDigestFailsForeignKey() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBImageRepository(db: db)
    await #expect(throws: PersistenceError.self) {
      try await repo.pin(ownerType: .profile, ownerId: "p", digest: ImageDigest(rawValue: "sha256:missing"))
    }
  }
}
