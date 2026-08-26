import GRDB
import RunnerCore

/// The reuse bookkeeping columns (spec §126). They are deliberately *not* part of `transition`:
/// none of them changes the state machine, and a taint has to be recordable on a row whose state
/// nobody is allowed to move (a `busy` VM keeps running its job).
///
/// `nil` leaves the column alone, so a caller that only wants to arm `retire_after_session` does
/// not have to restate the taint.
public struct ReuseUpdate: Sendable, Hashable {
  public var tainted: Bool?
  public var taintReason: String?
  public var retireAfterSession: Bool?
  /// Increments `jobs_consumed` by one. Also the guest cleanup epoch (spec §9.2).
  public var consumeJob: Bool

  public init(
    tainted: Bool? = nil, taintReason: String? = nil, retireAfterSession: Bool? = nil,
    consumeJob: Bool = false
  ) {
    self.tainted = tainted
    self.taintReason = taintReason
    self.retireAfterSession = retireAfterSession
    self.consumeJob = consumeJob
  }
}

public protocol InstanceRepository: Sendable {
  /// Inserts a brand-new instance row. Callers must have already reserved capacity: `planned`
  /// already consumes CPU/memory/disk against the host budget (spec §121).
  func insert(_ instance: InstanceRecord) async throws
  func get(id: InstanceID) async throws -> InstanceRecord?
  /// `profile` and `states` filters are ANDed; `nil` means "no filter on that dimension".
  func list(profile: RunnerProfileID?, states: Set<InstanceState>?) async throws -> [InstanceRecord]

  /// Single write transaction. CAS on `state` (fails with `PersistenceError.staleWrite` if the
  /// current state isn't `from`), and additionally on `worker_generation` when
  /// `expectedGeneration` is passed. Validates `from -> to` via `InstanceState.canTransition`
  /// (throws `StateTransitionError` on an illegal edge), then lets `mutate` set any other columns
  /// (timestamps, failure fields, ...) before persisting.
  @discardableResult
  func transition(
    id: InstanceID, from: InstanceState, to: InstanceState, expectedGeneration: Int?,
    mutate: @Sendable (inout InstanceRecord) -> Void
  ) async throws -> InstanceRecord

  /// Increments `worker_generation`, records the new `incarnationNonce`/`specDigest`, and clears
  /// the previous `worker_pid`/`worker_socket` (a new generation means a new worker process).
  /// Returns the new generation.
  @discardableResult
  func bumpWorkerGeneration(id: InstanceID, nonce: String, specDigest: String?) async throws -> Int

  /// All instances for `profile` whose state still consumes capacity (`InstanceState.consumesCapacity`,
  /// i.e. everything but `deleted`).
  func capacityConsuming(profile: RunnerProfileID) async throws -> [InstanceRecord]

  func markLastSeen(id: InstanceID) async throws

  /// Applies the reuse bookkeeping columns in one write transaction and returns the updated row.
  /// Never touches `state`, so it can run against an instance another actor owns.
  @discardableResult
  func applyReuse(id: InstanceID, _ update: ReuseUpdate) async throws -> InstanceRecord

  /// Hard-deletes the tombstone rows (`state = deleted`) that still reference `imageDigest`.
  /// `instances.image_digest` is a foreign key, so an image row cannot go while any instance row —
  /// even a deleted one — points at it. Only image GC calls this, and only after proving no live
  /// instance uses the image. Returns the number of rows removed.
  @discardableResult
  func purgeDeleted(imageDigest: ImageDigest) async throws -> Int
}

public final class GRDBInstanceRepository: InstanceRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func insert(_ instance: InstanceRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "instances") { try instance.insert(db) }
    }
  }

  public func get(id: InstanceID) async throws -> InstanceRecord? {
    try await db.read { db in try InstanceRecord.fetchOne(db, key: id) }
  }

  public func list(profile: RunnerProfileID?, states: Set<InstanceState>?) async throws -> [InstanceRecord] {
    try await db.read { db in
      var request = InstanceRecord.all()
      if let profile {
        request = request.filter(Column("profile_id") == profile.rawValue)
      }
      if let states {
        request = request.filter(states.map(\.rawValue).contains(Column("state")))
      }
      return try request.fetchAll(db)
    }
  }

  public func transition(
    id: InstanceID, from: InstanceState, to: InstanceState, expectedGeneration: Int?,
    mutate: @Sendable (inout InstanceRecord) -> Void
  ) async throws -> InstanceRecord {
    try await db.write { db in
      guard var record = try InstanceRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "instances", id: id.rawValue)
      }
      guard record.state == from else {
        throw PersistenceError.staleWrite(
          entity: "instances", id: id.rawValue, expectedState: from.rawValue, actualState: record.state.rawValue
        )
      }
      if let expectedGeneration, record.workerGeneration != expectedGeneration {
        throw PersistenceError.staleWrite(
          entity: "instances", id: id.rawValue,
          expectedState: "generation \(expectedGeneration)", actualState: "generation \(record.workerGeneration)"
        )
      }
      record.state = try from.transitioned(to: to)
      mutate(&record)
      try DatabaseErrorMapper.run(entity: "instances") { try record.update(db) }
      return record
    }
  }

  public func bumpWorkerGeneration(id: InstanceID, nonce: String, specDigest: String?) async throws -> Int {
    try await db.write { db in
      guard var record = try InstanceRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "instances", id: id.rawValue)
      }
      record.workerGeneration += 1
      record.incarnationNonce = nonce
      record.specDigest = specDigest
      record.workerPid = nil
      record.workerSocket = nil
      try DatabaseErrorMapper.run(entity: "instances") { try record.update(db) }
      return record.workerGeneration
    }
  }

  public func capacityConsuming(profile: RunnerProfileID) async throws -> [InstanceRecord] {
    try await db.read { db in
      try InstanceRecord
        .filter(Column("profile_id") == profile.rawValue)
        .filter(Column("state") != InstanceState.deleted.rawValue)
        .fetchAll(db)
    }
  }

  public func purgeDeleted(imageDigest: ImageDigest) async throws -> Int {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "instances") {
        try InstanceRecord
          .filter(Column("image_digest") == imageDigest.rawValue)
          .filter(Column("state") == InstanceState.deleted.rawValue)
          .deleteAll(db)
      }
    }
  }

  public func applyReuse(id: InstanceID, _ update: ReuseUpdate) async throws -> InstanceRecord {
    try await db.write { db in
      guard var record = try InstanceRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "instances", id: id.rawValue)
      }
      if let tainted = update.tainted { record.tainted = tainted }
      if let reason = update.taintReason { record.taintReason = reason }
      if let retire = update.retireAfterSession { record.retireAfterSession = retire }
      if update.consumeJob { record.jobsConsumed += 1 }
      try DatabaseErrorMapper.run(entity: "instances") { try record.update(db) }
      return record
    }
  }

  public func markLastSeen(id: InstanceID) async throws {
    try await db.write { db in
      guard var record = try InstanceRecord.fetchOne(db, key: id) else {
        throw PersistenceError.notFound(entity: "instances", id: id.rawValue)
      }
      record.lastSeenAt = .now
      try DatabaseErrorMapper.run(entity: "instances") { try record.update(db) }
    }
  }
}
