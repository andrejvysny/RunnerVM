import GRDB
import RunnerCore

public protocol ImageRepository: Sendable {
  func upsert(_ image: ImageRecord) async throws
  func get(digest: ImageDigest) async throws -> ImageRecord?
  func list(state: ImageState?) async throws -> [ImageRecord]

  /// Compare-and-swap on `images.state`, guarded by the local (non-RunnerCore) `pulling -> {ready,
  /// invalid, deleting}`, `ready|invalid -> deleting` graph — the schema has a CHECK on the value
  /// set but no transition table, so illegal edges surface as `PersistenceError.conflict` rather
  /// than a `StateTransitionError`.
  func setState(digest: ImageDigest, from: ImageState, to: ImageState) async throws

  /// Drops the row after the blobs are gone. Idempotent; the caller must have proven the image is
  /// unpinned and unreferenced first (`ImageManager.delete`).
  func delete(digest: ImageDigest) async throws

  /// Idempotent: pinning the same `(ownerType, ownerId, digest)` twice is a no-op.
  func pin(ownerType: ImagePinOwnerType, ownerId: String, digest: ImageDigest) async throws
  /// Idempotent: unpinning an absent pin is a no-op.
  func unpin(ownerType: ImagePinOwnerType, ownerId: String, digest: ImageDigest) async throws
  /// Drops every pin for one `(ownerType, ownerId)` regardless of digest. Used to release a
  /// `planning` reservation without first having to know which digest it landed on. Idempotent.
  func unpinOwner(ownerType: ImagePinOwnerType, ownerId: String) async throws
  func pinCount(digest: ImageDigest) async throws -> Int
  /// Every pin recorded under one owner type -- e.g. every `planning` reservation, for the
  /// startup sweep that drops ones whose instance row never landed.
  func pins(ownerType: ImagePinOwnerType) async throws -> [ImagePinRecord]
  /// Images with zero rows in `image_pins`, regardless of `state`.
  func unpinnedImages() async throws -> [ImageRecord]
}

public final class GRDBImageRepository: ImageRepository, Sendable {
  private static let allowedTransitions: [ImageState: Set<ImageState>] = [
    .pulling: [.ready, .invalid, .deleting],
    .ready: [.deleting],
    .invalid: [.deleting],
    .deleting: [],
  ]

  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func upsert(_ image: ImageRecord) async throws {
    try await db.write { db in
      // `digest` is both the business key and the primary key here, so a native
      // `INSERT ... ON CONFLICT(digest) DO UPDATE` is unambiguous (unlike the name-keyed
      // upsert in ScopeRepository/ProfileRepository, which must preserve a separate `id`).
      try DatabaseErrorMapper.run(entity: "images") { try image.upsert(db) }
    }
  }

  public func get(digest: ImageDigest) async throws -> ImageRecord? {
    try await db.read { db in try ImageRecord.fetchOne(db, key: digest) }
  }

  public func list(state: ImageState?) async throws -> [ImageRecord] {
    try await db.read { db in
      if let state {
        try ImageRecord.filter(Column("state") == state.rawValue).fetchAll(db)
      } else {
        try ImageRecord.fetchAll(db)
      }
    }
  }

  public func setState(digest: ImageDigest, from: ImageState, to: ImageState) async throws {
    try await db.write { db in
      guard var record = try ImageRecord.fetchOne(db, key: digest) else {
        throw PersistenceError.notFound(entity: "images", id: digest.rawValue)
      }
      guard record.state == from else {
        throw PersistenceError.staleWrite(
          entity: "images", id: digest.rawValue, expectedState: from.rawValue, actualState: record.state.rawValue
        )
      }
      guard Self.allowedTransitions[from]?.contains(to) == true else {
        throw PersistenceError.conflict(entity: "images", reason: "illegal state transition \(from.rawValue) -> \(to.rawValue)")
      }
      record.state = to
      try DatabaseErrorMapper.run(entity: "images") { try record.update(db) }
    }
  }

  public func delete(digest: ImageDigest) async throws {
    try await db.write { db in
      _ = try DatabaseErrorMapper.run(entity: "images") { try ImageRecord.deleteOne(db, key: digest) }
    }
  }

  public func pin(ownerType: ImagePinOwnerType, ownerId: String, digest: ImageDigest) async throws {
    try await db.write { db in
      let pin = ImagePinRecord(ownerType: ownerType, ownerId: ownerId, digest: digest, createdAt: .now)
      try DatabaseErrorMapper.run(entity: "image_pins") { try pin.insert(db, onConflict: .ignore) }
    }
  }

  public func unpin(ownerType: ImagePinOwnerType, ownerId: String, digest: ImageDigest) async throws {
    try await db.write { db in
      _ = try ImagePinRecord.deleteOne(
        db, key: ["owner_type": ownerType.rawValue, "owner_id": ownerId, "digest": digest.rawValue]
      )
    }
  }

  public func unpinOwner(ownerType: ImagePinOwnerType, ownerId: String) async throws {
    try await db.write { db in
      _ = try ImagePinRecord
        .filter(Column("owner_type") == ownerType.rawValue)
        .filter(Column("owner_id") == ownerId)
        .deleteAll(db)
    }
  }

  public func pinCount(digest: ImageDigest) async throws -> Int {
    try await db.read { db in
      try ImagePinRecord.filter(Column("digest") == digest.rawValue).fetchCount(db)
    }
  }

  public func pins(ownerType: ImagePinOwnerType) async throws -> [ImagePinRecord] {
    try await db.read { db in
      try ImagePinRecord.filter(Column("owner_type") == ownerType.rawValue).fetchAll(db)
    }
  }

  public func unpinnedImages() async throws -> [ImageRecord] {
    try await db.read { db in
      // A small, fully static SQL literal (no interpolated values) reads more directly than the
      // query-interface's subquery-`contains` spelling here.
      try ImageRecord.fetchAll(
        db, sql: "SELECT * FROM images WHERE digest NOT IN (SELECT digest FROM image_pins)"
      )
    }
  }
}
