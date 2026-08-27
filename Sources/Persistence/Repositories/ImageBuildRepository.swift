import GRDB
import RunnerCore

public protocol ImageBuildRepository: Sendable {
  /// Inserts a build row that already has everything it needs (no companion operation). Most
  /// callers should prefer `create(_:operation:)`.
  func insert(_ build: ImageBuildRecord) async throws

  /// Inserts the build row and its `operations` row in one write transaction, so a reader never
  /// observes a build with no operation to follow, or an operation with no build behind it.
  func create(_ build: ImageBuildRecord, operation: OperationRecord) async throws

  func get(id: ImageBuildID) async throws -> ImageBuildRecord?
  /// `nil` means "no filter" -- every build, in any state.
  func list(states: Set<ImageBuildState>?) async throws -> [ImageBuildRecord]

  /// Single write transaction. CAS on `state` (fails with `PersistenceError.staleWrite` if the
  /// current state isn't `from`), validated via `ImageBuildState.canTransition` (throws
  /// `StateTransitionError` on an illegal edge), then lets `mutate` set any other columns before
  /// persisting. Mirrors `InstanceRepository.transition`.
  @discardableResult
  func transition(
    id: ImageBuildID, from: ImageBuildState, to: ImageBuildState,
    mutate: @Sendable (inout ImageBuildRecord) -> Void
  ) async throws -> ImageBuildRecord

  /// Updates step progress without touching `state`, so it can be called from a worker-callback
  /// path that runs concurrently with a state transition landing.
  func recordProgress(
    id: ImageBuildID, step: Int, total: Int?, instruction: String?
  ) async throws

  func setWorker(id: ImageBuildID, pid: Int32?, nonce: String?) async throws
  func setImageDigest(id: ImageBuildID, _ digest: ImageDigest) async throws

  /// Stamps (or clears, with `nil`) the instant restart recovery first found this build's builder
  /// worker alive-or-unverifiable. Deliberately not part of `transition`: a pending build keeps
  /// its state, so there is no edge to ride along with.
  func setRecoverySince(id: ImageBuildID, _ since: DatabaseDate?) async throws
  func setPushOperation(id: ImageBuildID, _ operationId: OperationID) async throws

  /// Hard-deletes terminal build rows older than `olderThan`. Returns the number of rows removed.
  @discardableResult
  func purge(olderThan: DatabaseDate) async throws -> Int
}

public final class GRDBImageBuildRepository: ImageBuildRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func insert(_ build: ImageBuildRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "image_builds") { try build.insert(db) }
    }
  }

  public func create(_ build: ImageBuildRecord, operation: OperationRecord) async throws {
    try await db.write { db in
      // The operation first: `image_builds.operation_id` is a foreign key into `operations`, so a
      // build row that already names its operation cannot be inserted before it exists.
      try DatabaseErrorMapper.run(entity: "operations") { try operation.insert(db) }
      try DatabaseErrorMapper.run(entity: "image_builds") { try build.insert(db) }
    }
  }

  public func get(id: ImageBuildID) async throws -> ImageBuildRecord? {
    try await db.read { db in try ImageBuildRecord.fetchOne(db, key: id) }
  }

  public func list(states: Set<ImageBuildState>?) async throws -> [ImageBuildRecord] {
    try await db.read { db in
      var request = ImageBuildRecord.all()
      if let states {
        request = request.filter(states.map(\.rawValue).contains(Column("state")))
      }
      return try request.fetchAll(db)
    }
  }

  public func transition(
    id: ImageBuildID, from: ImageBuildState, to: ImageBuildState,
    mutate: @Sendable (inout ImageBuildRecord) -> Void
  ) async throws -> ImageBuildRecord {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      guard record.state == from else {
        throw PersistenceError.staleWrite(
          entity: "image_builds", id: id.rawValue, expectedState: from.rawValue,
          actualState: record.state.rawValue
        )
      }
      record.state = try from.transitioned(to: to)
      mutate(&record)
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
      return record
    }
  }

  public func recordProgress(
    id: ImageBuildID, step: Int, total: Int?, instruction: String?
  ) async throws {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      record.currentStep = step
      if let total { record.totalSteps = total }
      record.currentInstruction = instruction
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
    }
  }

  public func setWorker(id: ImageBuildID, pid: Int32?, nonce: String?) async throws {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      record.workerPid = pid
      record.workerNonce = nonce
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
    }
  }

  public func setImageDigest(id: ImageBuildID, _ digest: ImageDigest) async throws {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      record.imageDigest = digest
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
    }
  }

  public func setRecoverySince(id: ImageBuildID, _ since: DatabaseDate?) async throws {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      record.recoverySince = since
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
    }
  }

  public func setPushOperation(id: ImageBuildID, _ operationId: OperationID) async throws {
    try await db.write { db in
      guard var record = try ImageBuildRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "image_builds", id: id.rawValue)
      }
      record.pushOperationId = operationId
      try DatabaseErrorMapper.run(entity: "image_builds") { try record.update(db) }
    }
  }

  public func purge(olderThan: DatabaseDate) async throws -> Int {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "image_builds") {
        try ImageBuildRecord
          .filter(Self.terminalStates.contains(Column("state")))
          .filter(Column("created_at") < olderThan)
          .deleteAll(db)
      }
    }
  }

  private static let terminalStates =
    [ImageBuildState.succeeded, .failed, .cancelled].map(\.rawValue)
}
