import RunnerCore
import Testing
@testable import Persistence

@Suite struct ScaleSetRepositoryTests {
  private func seedScaleSet(db: RunnerDatabase) async throws -> ScaleSetRecord {
    let (_, _, profileId, _) = try await Fixtures.seedProfileChain(db: db)
    return try await GRDBScaleSetRepository(db: db).ensureScaleSet(
      profileId: profileId, githubScaleSetName: "acme-linux-default"
    )
  }

  @Test func ensureScaleSetIsIdempotent() async throws {
    let db = try TestDatabase.make()
    let (_, _, profileId, _) = try await Fixtures.seedProfileChain(db: db)
    let repo = GRDBScaleSetRepository(db: db)

    let first = try await repo.ensureScaleSet(profileId: profileId, githubScaleSetName: "acme-linux-default")
    let second = try await repo.ensureScaleSet(profileId: profileId, githubScaleSetName: "acme-linux-default")
    #expect(first.id == second.id)
    #expect(try await repo.get(profileId: profileId)?.id == first.id)
  }

  @Test func openSessionGenerationsIncreaseMonotonically() async throws {
    let db = try TestDatabase.make()
    let scaleSet = try await seedScaleSet(db: db)
    let repo = GRDBScaleSetRepository(db: db)

    let g0 = try await repo.openSession(scaleSetId: scaleSet.id)
    let g1 = try await repo.openSession(scaleSetId: scaleSet.id)
    #expect(g0 == 0)
    #expect(g1 == 1)

    let current = try #require(try await repo.currentSession(scaleSetId: scaleSet.id))
    #expect(current.sessionGeneration == 1)
  }

  @Test func advanceCursorOnlyMovesForward() async throws {
    let db = try TestDatabase.make()
    let scaleSet = try await seedScaleSet(db: db)
    let repo = GRDBScaleSetRepository(db: db)
    let generation = try await repo.openSession(scaleSetId: scaleSet.id)

    try await repo.advanceCursor(scaleSetId: scaleSet.id, generation: generation, messageId: 5)
    var current = try #require(try await repo.currentSession(scaleSetId: scaleSet.id))
    #expect(current.lastMessageId == 5)

    try await repo.advanceCursor(scaleSetId: scaleSet.id, generation: generation, messageId: 2) // stale, ignored
    current = try #require(try await repo.currentSession(scaleSetId: scaleSet.id))
    #expect(current.lastMessageId == 5)

    try await repo.advanceCursor(scaleSetId: scaleSet.id, generation: generation, messageId: 9)
    current = try #require(try await repo.currentSession(scaleSetId: scaleSet.id))
    #expect(current.lastMessageId == 9)
  }

  @Test func recordIntentIsIdempotent() async throws {
    let db = try TestDatabase.make()
    let scaleSet = try await seedScaleSet(db: db)
    let repo = GRDBScaleSetRepository(db: db)
    let generation = try await repo.openSession(scaleSetId: scaleSet.id)

    try await repo.recordIntent(
      scaleSetId: scaleSet.id, generation: generation, messageId: 1, messageType: "jobAvailable", bodyJson: "{}"
    )
    try await repo.recordIntent(
      scaleSetId: scaleSet.id, generation: generation, messageId: 1, messageType: "jobAvailable", bodyJson: "{}"
    )

    let pending = try await repo.pendingIntents(scaleSetId: scaleSet.id, generation: generation)
    #expect(pending.count == 1)
  }

  @Test func markProcessedAndDeletedRemoveFromPendingIntents() async throws {
    let db = try TestDatabase.make()
    let scaleSet = try await seedScaleSet(db: db)
    let repo = GRDBScaleSetRepository(db: db)
    let generation = try await repo.openSession(scaleSetId: scaleSet.id)

    try await repo.recordIntent(
      scaleSetId: scaleSet.id, generation: generation, messageId: 1, messageType: "a", bodyJson: "{}"
    )
    try await repo.recordIntent(
      scaleSetId: scaleSet.id, generation: generation, messageId: 2, messageType: "b", bodyJson: "{}"
    )

    try await repo.markProcessed(scaleSetId: scaleSet.id, generation: generation, messageId: 1)
    try await repo.markDeleted(scaleSetId: scaleSet.id, generation: generation, messageId: 2)

    let pending = try await repo.pendingIntents(scaleSetId: scaleSet.id, generation: generation)
    #expect(pending.isEmpty)
  }

  @Test func pendingIntentsOrderedByMessageId() async throws {
    let db = try TestDatabase.make()
    let scaleSet = try await seedScaleSet(db: db)
    let repo = GRDBScaleSetRepository(db: db)
    let generation = try await repo.openSession(scaleSetId: scaleSet.id)

    for messageId in [3, 1, 2] {
      try await repo.recordIntent(
        scaleSetId: scaleSet.id, generation: generation, messageId: Int64(messageId), messageType: "x", bodyJson: "{}"
      )
    }

    let pending = try await repo.pendingIntents(scaleSetId: scaleSet.id, generation: generation)
    #expect(pending.map(\.messageId) == [1, 2, 3])
  }
}
