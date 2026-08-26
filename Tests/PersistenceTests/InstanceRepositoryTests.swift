import Foundation
import RunnerCore
import Testing
@testable import Persistence

@Suite struct InstanceRepositoryTests {
  private func seedInstance(db: RunnerDatabase) async throws -> InstanceRecord {
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    let instance = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await GRDBInstanceRepository(db: db).insert(instance)
    return instance
  }

  @Test func insertAndGet() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)
    let fetched = try #require(try await repo.get(id: instance.id))
    #expect(fetched.state == .planned)
    #expect(fetched.workerGeneration == 0)
  }

  @Test func transitionHappyPathWalksThroughStates() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)

    let afterPreparing = try await repo.transition(
      id: instance.id, from: .planned, to: .preparing, expectedGeneration: nil
    ) { _ in }
    #expect(afterPreparing.state == .preparing)

    let afterCloning = try await repo.transition(
      id: instance.id, from: .preparing, to: .cloning, expectedGeneration: nil
    ) { record in record.startedAt = .now }
    #expect(afterCloning.state == .cloning)
    #expect(afterCloning.startedAt != nil)
  }

  @Test func transitionRejectsWrongCurrentState() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)

    await #expect(throws: PersistenceError.self) {
      try await repo.transition(id: instance.id, from: .idle, to: .busy, expectedGeneration: nil) { _ in }
    }
  }

  @Test func transitionRejectsIllegalEdge() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db) // state == .planned
    let repo = GRDBInstanceRepository(db: db)

    // idle -> deleted is not a legal InstanceState edge, but we need to reach idle first via a
    // legal-shaped CAS check: assert directly against planned -> idle, which is also illegal
    // (planned only allows preparing/failed/deleting).
    await #expect(throws: StateTransitionError.self) {
      try await repo.transition(id: instance.id, from: .planned, to: .idle, expectedGeneration: nil) { _ in }
    }
  }

  @Test func bumpWorkerGenerationIncrementsAndResetsWorkerFields() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)

    let newGeneration = try await repo.bumpWorkerGeneration(id: instance.id, nonce: "nonce-1", specDigest: "spec-1")
    #expect(newGeneration == 1)

    let fetched = try #require(try await repo.get(id: instance.id))
    #expect(fetched.workerGeneration == 1)
    #expect(fetched.incarnationNonce == "nonce-1")
    #expect(fetched.specDigest == "spec-1")
  }

  @Test func transitionWithExpectedGenerationMismatchFails() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)
    _ = try await repo.bumpWorkerGeneration(id: instance.id, nonce: "n1", specDigest: nil) // generation -> 1

    await #expect(throws: PersistenceError.self) {
      try await repo.transition(
        id: instance.id, from: .planned, to: .preparing, expectedGeneration: 0
      ) { _ in }
    }
    // The failed CAS must not have applied the state change.
    let fetched = try #require(try await repo.get(id: instance.id))
    #expect(fetched.state == .planned)
  }

  @Test func transitionWithMatchingExpectedGenerationSucceeds() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)
    _ = try await repo.bumpWorkerGeneration(id: instance.id, nonce: "n1", specDigest: nil) // generation -> 1

    let result = try await repo.transition(
      id: instance.id, from: .planned, to: .preparing, expectedGeneration: 1
    ) { _ in }
    #expect(result.state == .preparing)
  }

  @Test func capacityConsumingExcludesOnlyDeleted() async throws {
    let db = try TestDatabase.make()
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    let repo = GRDBInstanceRepository(db: db)

    let stillConsuming = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await repo.insert(stillConsuming)

    let deleted = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await repo.insert(deleted)
    for path in [InstanceState.preparing, .cloning, .startingWorker, .failed, .deleting, .deleted] {
      _ = try await repo.transition(id: deleted.id, from: try lastState(path), to: path, expectedGeneration: nil) { _ in }
    }

    let consuming = try await repo.capacityConsuming(profile: profileId)
    #expect(consuming.map(\.id) == [stillConsuming.id])
  }

  /// The predecessor of `state` along the `planned -> preparing -> cloning -> startingWorker ->
  /// failed -> deleting -> deleted` path used by `capacityConsumingExcludesOnlyDeleted`.
  private func lastState(_ state: InstanceState) throws -> InstanceState {
    switch state {
    case .preparing: .planned
    case .cloning: .preparing
    case .startingWorker: .cloning
    case .failed: .startingWorker
    case .deleting: .failed
    case .deleted: .deleting
    default: .planned
    }
  }

  @Test func markLastSeenSetsTimestamp() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBInstanceRepository(db: db)
    #expect(try #require(try await repo.get(id: instance.id)).lastSeenAt == nil)

    try await repo.markLastSeen(id: instance.id)
    #expect(try #require(try await repo.get(id: instance.id)).lastSeenAt != nil)
  }

  @Test func listFiltersByProfileAndStates() async throws {
    let db = try TestDatabase.make()
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    let repo = GRDBInstanceRepository(db: db)
    let a = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    let b = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await repo.insert(a)
    try await repo.insert(b)
    _ = try await repo.transition(id: a.id, from: .planned, to: .preparing, expectedGeneration: nil) { _ in }

    let preparingOnly = try await repo.list(profile: profileId, states: [.preparing])
    #expect(preparingOnly.map(\.id) == [a.id])

    let all = try await repo.list(profile: profileId, states: nil)
    #expect(Set(all.map(\.id)) == Set([a.id, b.id]))
  }
}
