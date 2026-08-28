import Foundation
import RunnerCore
import Testing
@testable import Persistence

/// Minimal, FK-valid `image_builds` fixtures. Every build needs a host row (already ensured by
/// `TestDatabase`'s bare `RunnerDatabase.inMemory()`? -- no, `image_builds.host_id` references
/// `host(id)`, so each test seeds one explicitly, same as `Fixtures.seedProfileChain` does for the
/// instance chain).
private enum BuildFixtures {
  static func build(
    id: ImageBuildID = .generate(), hostId: HostID = Fixtures.hostID, name: String? = "test-build",
    state: ImageBuildState = .queued
  ) -> ImageBuildRecord {
    ImageBuildRecord(
      id: id, hostId: hostId, name: name, state: state, recipePath: "/tmp/Runnerfile",
      recipeSHA256: String(repeating: "a", count: 64), contextPath: "/tmp/context",
      fromKind: .image, fromReference: "ubuntu-24", cpuCount: 4,
      memoryBytes: ByteSize.gibibytes(4).bytes, diskBytes: ByteSize.gibibytes(16).bytes,
      diskReservationBytes: ByteSize.gibibytes(16).bytes, timeoutMs: 3_600_000,
      buildPath: "/var/lib/runnervm/builds/\(id.rawValue)",
      logPath: "/var/lib/runnervm/logs/builds/\(id.rawValue)/build.log",
      createdAt: .now, updatedAt: .now
    )
  }

  static func operation(resourceId: String) -> OperationRecord {
    OperationRecord(
      id: .generate(), kind: "image-build", resourceType: "image_build", resourceId: resourceId,
      state: .running, startedAt: .now
    )
  }
}

@Suite struct ImageBuildRepositoryTests {
  /// Hoisted out of the `#expect(throws:)` call sites below: inlining a closure literal there
  /// makes Swift 6.1's type checker choke on the combination of `inout ImageBuildRecord`, the
  /// async throwing macro expansion and generic error matching (same family of issue as the
  /// `@Test(arguments:)` timeout fixed for `ByteSizeTests`).
  private static let noopMutate: @Sendable (inout ImageBuildRecord) -> Void = { _ in }

  private func seededDB() async throws -> RunnerDatabase {
    let db = try TestDatabase.make()
    _ = try await GRDBHostRepository(db: db).ensureHost(id: Fixtures.hostID)
    return db
  }

  @Test func insertThenGet() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build()
    try await repo.insert(build)

    let fetched = try #require(try await repo.get(id: build.id))
    #expect(fetched.state == .queued)
    #expect(fetched.name == "test-build")
    #expect(fetched.fromKind == .image)
  }

  @Test func listFiltersByStates() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let queued = BuildFixtures.build(name: "queued")
    let sealing = BuildFixtures.build(name: "sealing", state: .sealing)
    try await repo.insert(queued)
    try await repo.insert(sealing)

    #expect(try await repo.list(states: nil).count == 2)
    let filtered = try await repo.list(states: [.sealing])
    #expect(filtered.map(\.id) == [sealing.id])
  }

  /// `create` writes the build row and its companion operation row in one transaction, so both are
  /// visible together -- there is no window where a reader sees one but not the other.
  @Test func createWritesBuildAndOperationAtomically() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build()
    let operation = BuildFixtures.operation(resourceId: build.id.rawValue)

    try await repo.create(build, operation: operation)

    #expect(try await repo.get(id: build.id) != nil)
    let operations = GRDBOperationRepository(db: db)
    let fetchedOperation = try await operations.list(state: nil).first { $0.id == operation.id }
    #expect(fetchedOperation?.resourceId == build.id.rawValue)
  }

  @Test func transitionHappyPathUpdatesStateAndOtherColumns() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build()
    try await repo.insert(build)

    let updated = try await repo.transition(id: build.id, from: .queued, to: .resolving) {
      $0.currentInstruction = "resolving FROM"
    }

    #expect(updated.state == .resolving)
    #expect(updated.currentInstruction == "resolving FROM")
    let refetched = try #require(try await repo.get(id: build.id))
    #expect(refetched.state == .resolving)
  }

  @Test func transitionRejectsWrongCurrentState() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build() // state == .queued
    try await repo.insert(build)

    await #expect(throws: PersistenceError.self) {
      _ = try await repo.transition(id: build.id, from: .sealing, to: .succeeded, mutate: Self.noopMutate)
    }
  }

  @Test func transitionRejectsIllegalEdge() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build() // state == .queued
    try await repo.insert(build)

    await #expect(throws: StateTransitionError.self) {
      _ = try await repo.transition(id: build.id, from: .queued, to: .sealing, mutate: Self.noopMutate)
    }
  }

  @Test func recordProgressLeavesStateUntouched() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build(state: .provisioning)
    try await repo.insert(build)

    try await repo.recordProgress(id: build.id, step: 3, total: 8, instruction: "RUN apt-get update")

    let fetched = try #require(try await repo.get(id: build.id))
    #expect(fetched.state == .provisioning)
    #expect(fetched.currentStep == 3)
    #expect(fetched.totalSteps == 8)
    #expect(fetched.currentInstruction == "RUN apt-get update")
  }

  @Test func setWorkerImageDigestAndPushOperationUpdateTheirColumns() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build()
    try await repo.insert(build)

    try await repo.setWorker(id: build.id, pid: 4_242, nonce: "nonce-1")
    try await repo.setImageDigest(id: build.id, ImageDigest(rawValue: "sha256:" + String(repeating: "b", count: 64)))
    let pushOp = try await GRDBOperationRepository(db: db).start(
      kind: "push", resourceType: "image_build", resourceId: build.id.rawValue, idempotencyKey: nil)
    try await repo.setPushOperation(id: build.id, pushOp.id)

    let fetched = try #require(try await repo.get(id: build.id))
    #expect(fetched.workerPid == 4_242)
    #expect(fetched.workerNonce == "nonce-1")
    #expect(fetched.imageDigest?.rawValue == "sha256:" + String(repeating: "b", count: 64))
    #expect(fetched.pushOperationId == pushOp.id)
  }

  @Test func purgeRemovesOnlyOldTerminalBuilds() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let old = BuildFixtures.build(name: "old", state: .succeeded)
    let recent = BuildFixtures.build(name: "recent", state: .succeeded)
    let stillRunning = BuildFixtures.build(name: "running", state: .booting)
    try await repo.insert(old)
    try await repo.insert(recent)
    try await repo.insert(stillRunning)

    // Backdate `old` directly; `purge` compares against `created_at`.
    try await db.write { db in
      try db.execute(
        sql: "UPDATE image_builds SET created_at = ? WHERE id = ?",
        arguments: [DatabaseDate(Date().addingTimeInterval(-90 * 86_400)), old.id.rawValue]
      )
    }

    let cutoff = DatabaseDate(Date().addingTimeInterval(-30 * 86_400))
    let removed = try await repo.purge(olderThan: cutoff)

    #expect(removed == 1)
    #expect(try await repo.get(id: old.id) == nil)
    #expect(try await repo.get(id: recent.id) != nil)
    #expect(try await repo.get(id: stillRunning.id) != nil)
  }

  @Test func insertedBuildDefaultsToRunnerfileKindWithNoManagedLink() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    let build = BuildFixtures.build()
    try await repo.insert(build)

    let fetched = try #require(try await repo.get(id: build.id))
    #expect(fetched.kind == .runnerfile)
    #expect(fetched.managedName == nil)
    #expect(fetched.sourceDigest == nil)
  }

  @Test func explicitMacosProvisionKindManagedNameAndSourceDigestRoundTrip() async throws {
    let db = try await seededDB()
    let repo = GRDBImageBuildRepository(db: db)
    var build = BuildFixtures.build()
    build.kind = .macosProvision
    build.managedName = "macos-sequoia"
    build.sourceDigest = "sha256:" + String(repeating: "c", count: 64)
    try await repo.insert(build)

    let fetched = try #require(try await repo.get(id: build.id))
    #expect(fetched.kind == .macosProvision)
    #expect(fetched.managedName == "macos-sequoia")
    #expect(fetched.sourceDigest == "sha256:" + String(repeating: "c", count: 64))
  }

  @Test func bogusStateIsRejectedByTheCheckConstraint() async throws {
    let db = try await seededDB()
    await #expect(throws: (any Error).self) {
      try await db.write { db in
        try db.execute(
          sql: """
          INSERT INTO image_builds (
            id, host_id, state, recipe_path, recipe_sha256, context_path, from_kind, from_reference,
            cpu_count, memory_bytes, disk_bytes, disk_reservation_bytes, timeout_ms, build_path,
            log_path, created_at, updated_at
          ) VALUES (?, ?, 'bogus', '/r', ?, '/c', 'image', 'ubuntu', 4, 1, 1, 1, 1, '/b', '/l', ?, ?)
          """,
          arguments: [
            ImageBuildID.generate().rawValue, Fixtures.hostID.rawValue,
            String(repeating: "a", count: 64), DatabaseDate.now, DatabaseDate.now,
          ]
        )
      }
    }
  }

  @Test func bogusFromKindIsRejectedByTheCheckConstraint() async throws {
    let db = try await seededDB()
    await #expect(throws: (any Error).self) {
      try await db.write { db in
        try db.execute(
          sql: """
          INSERT INTO image_builds (
            id, host_id, state, recipe_path, recipe_sha256, context_path, from_kind, from_reference,
            cpu_count, memory_bytes, disk_bytes, disk_reservation_bytes, timeout_ms, build_path,
            log_path, created_at, updated_at
          ) VALUES (?, ?, 'queued', '/r', ?, '/c', 'bogus', 'ubuntu', 4, 1, 1, 1, 1, '/b', '/l', ?, ?)
          """,
          arguments: [
            ImageBuildID.generate().rawValue, Fixtures.hostID.rawValue,
            String(repeating: "a", count: 64), DatabaseDate.now, DatabaseDate.now,
          ]
        )
      }
    }
  }
}
