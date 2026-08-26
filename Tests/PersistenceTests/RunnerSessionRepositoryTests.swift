import RunnerCore
import Testing
@testable import Persistence

@Suite struct RunnerSessionRepositoryTests {
  private func seedInstance(db: RunnerDatabase) async throws -> InstanceRecord {
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    let instance = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await GRDBInstanceRepository(db: db).insert(instance)
    return instance
  }

  @Test func insertAndGet() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let session = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    let repo = GRDBRunnerSessionRepository(db: db)
    try await repo.insert(session)

    let fetched = try #require(try await repo.get(id: session.id))
    #expect(fetched.state == .planned)
    #expect(fetched.jitSource == .scaleSet)
  }

  @Test func transitionHappyPathStampsUpdatedAt() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let session = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    let repo = GRDBRunnerSessionRepository(db: db)
    try await repo.insert(session)

    let updated = try await repo.transition(id: session.id, from: .planned, to: .jitRequested) { record in
      record.githubJobRequestId = "job-1"
    }
    #expect(updated.state == .jitRequested)
    #expect(updated.githubJobRequestId == "job-1")
    #expect(updated.updatedAt > session.updatedAt || updated.updatedAt == session.updatedAt)
  }

  @Test func transitionRejectsWrongCurrentState() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let session = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    let repo = GRDBRunnerSessionRepository(db: db)
    try await repo.insert(session)

    await #expect(throws: PersistenceError.self) {
      try await repo.transition(id: session.id, from: .runnerOnline, to: .jobRunning) { _ in }
    }
  }

  @Test func transitionRejectsIllegalEdge() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let session = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    let repo = GRDBRunnerSessionRepository(db: db)
    try await repo.insert(session)

    await #expect(throws: StateTransitionError.self) {
      try await repo.transition(id: session.id, from: .planned, to: .jobRunning) { _ in }
    }
  }

  @Test func listActiveExcludesTerminalSessions() async throws {
    let db = try TestDatabase.make()
    let instance = try await seedInstance(db: db)
    let repo = GRDBRunnerSessionRepository(db: db)

    let active = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    try await repo.insert(active)
    _ = try await repo.transition(id: active.id, from: .planned, to: .jitRequested) { _ in }

    let terminal = Fixtures.runnerSession(instanceId: instance.id, profileId: instance.profileId)
    try await repo.insert(terminal)
    _ = try await repo.transition(id: terminal.id, from: .planned, to: .jitFailed) { _ in }

    let actives = try await repo.listActive(instance: instance.id)
    #expect(actives.map(\.id) == [active.id])
  }
}
