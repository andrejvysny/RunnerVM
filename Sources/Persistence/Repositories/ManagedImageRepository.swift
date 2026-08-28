import GRDB
import RunnerCore

public protocol ManagedImageRepository: Sendable {
  /// Insert-or-update by `name` (the table's primary key). Callers pass a fully-formed record;
  /// there is no partial-update variant, mirroring `ImageRepository`'s alias `upsert`.
  func upsert(_ record: ManagedImageRecord) async throws

  func get(name: String) async throws -> ManagedImageRecord?
  func list() async throws -> [ManagedImageRecord]
  /// Every managed image of `kind`, in any state.
  func list(kind: ManagedImageKind) async throws -> [ManagedImageRecord]

  /// Single write transaction. CAS on `state` (fails with `PersistenceError.staleWrite` if the
  /// current state isn't `from`), validated via `ManagedImageState.canTransition` (throws
  /// `StateTransitionError` on an illegal edge), then lets `mutate` set any other columns before
  /// persisting. Stamps `updated_at`. Mirrors `ImageBuildRepository.transition`.
  @discardableResult
  func transition(
    name: String, from: ManagedImageState, to: ManagedImageState,
    mutate: @Sendable (inout ManagedImageRecord) -> Void
  ) async throws -> ManagedImageRecord

  func delete(name: String) async throws
}

public final class GRDBManagedImageRepository: ManagedImageRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func upsert(_ record: ManagedImageRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "managed_images") { try record.upsert(db) }
    }
  }

  public func get(name: String) async throws -> ManagedImageRecord? {
    try await db.read { db in try ManagedImageRecord.fetchOne(db, key: name) }
  }

  public func list() async throws -> [ManagedImageRecord] {
    try await db.read { db in try ManagedImageRecord.fetchAll(db) }
  }

  public func list(kind: ManagedImageKind) async throws -> [ManagedImageRecord] {
    try await db.read { db in
      try ManagedImageRecord.filter(Column("kind") == kind.rawValue).fetchAll(db)
    }
  }

  public func transition(
    name: String, from: ManagedImageState, to: ManagedImageState,
    mutate: @Sendable (inout ManagedImageRecord) -> Void
  ) async throws -> ManagedImageRecord {
    try await db.write { db in
      guard var record = try ManagedImageRecord.fetchOne(db, key: name) else {
        throw PersistenceError.notFound(entity: "managed_images", id: name)
      }
      guard record.state == from else {
        throw PersistenceError.staleWrite(
          entity: "managed_images", id: name, expectedState: from.rawValue, actualState: record.state.rawValue
        )
      }
      record.state = try from.transitioned(to: to)
      record.updatedAt = .now
      mutate(&record)
      try DatabaseErrorMapper.run(entity: "managed_images") { try record.update(db) }
      return record
    }
  }

  public func delete(name: String) async throws {
    try await db.write { db in
      _ = try DatabaseErrorMapper.run(entity: "managed_images") {
        try ManagedImageRecord.deleteOne(db, key: name)
      }
    }
  }
}
