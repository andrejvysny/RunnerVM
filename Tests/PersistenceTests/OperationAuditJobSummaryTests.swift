import RunnerCore
import Testing
@testable import Persistence

@Suite struct OperationRepositoryTests {
  @Test func startIsIdempotentByKey() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBOperationRepository(db: db)

    let first = try await repo.start(
      kind: "pull-image", resourceType: "images", resourceId: "sha256:abc", idempotencyKey: "op-1"
    )
    let second = try await repo.start(
      kind: "pull-image", resourceType: "images", resourceId: "sha256:abc", idempotencyKey: "op-1"
    )
    #expect(first.id == second.id)
    #expect(first.state == .running)

    let all = try await repo.list(state: nil)
    #expect(all.count == 1)
  }

  @Test func startWithoutKeyAlwaysInserts() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBOperationRepository(db: db)
    _ = try await repo.start(kind: "reconcile", resourceType: "host", resourceId: "host-1", idempotencyKey: nil)
    _ = try await repo.start(kind: "reconcile", resourceType: "host", resourceId: "host-1", idempotencyKey: nil)
    #expect(try await repo.list(state: nil).count == 2)
  }

  @Test func finishSetsTerminalStateAndError() async throws {
    let db = try TestDatabase.make()
    let repo = GRDBOperationRepository(db: db)
    let op = try await repo.start(kind: "clone-instance", resourceType: "instances", resourceId: "i-1", idempotencyKey: nil)

    try await repo.finish(id: op.id, state: .failed, errorCode: "CLONE_FAILED", errorMessage: "disk full")

    let failed = try await repo.list(state: .failed)
    #expect(failed.map(\.id) == [op.id])
    #expect(failed.first?.errorCode == "CLONE_FAILED")
    #expect(failed.first?.finishedAt != nil)
  }
}

@Suite struct JobSummaryRepositoryTests {
  @Test func insertPersists() async throws {
    let db = try TestDatabase.make()
    let (hostId, _, profileId, digest) = try await Fixtures.seedProfileChain(db: db)
    let instance = Fixtures.instance(profileId: profileId, imageDigest: digest, hostId: hostId)
    try await GRDBInstanceRepository(db: db).insert(instance)
    let session = Fixtures.runnerSession(instanceId: instance.id, profileId: profileId)
    try await GRDBRunnerSessionRepository(db: db).insert(session)

    let summary = JobSummaryRecord(
      id: .generateID(), runnerSessionId: session.id, jobDurationMs: 42_000, createdAt: .now
    )
    try await GRDBJobSummaryRepository(db: db).insert(summary)

    let rows = try await db.read { db in try JobSummaryRecord.fetchAll(db) }
    #expect(rows.map(\.id) == [summary.id])
  }
}

@Suite struct AuditRepositoryTests {
  @Test func recordInsertsAnEvent() async throws {
    let db = try TestDatabase.make()
    try await GRDBAuditRepository(db: db).record(
      kind: "instance.deleted", actor: "runnerd", resourceType: "instances", resourceId: "i-1", detail: "{}"
    )

    let rows = try await db.read { db in try AuditEventRecord.fetchAll(db) }
    #expect(rows.count == 1)
    #expect(rows.first?.kind == "instance.deleted")
  }
}
