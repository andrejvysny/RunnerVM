import GRDB
import RunnerCore

public protocol ScaleSetRepository: Sendable {
  /// Inserts the scale set row for `profileId` if absent (spec §100/§4897 `ensureScaleSet`
  /// naming), returning the existing row unchanged otherwise. `profile_id` is `UNIQUE`.
  @discardableResult
  func ensureScaleSet(profileId: RunnerProfileID, githubScaleSetName: String) async throws -> ScaleSetRecord
  func get(profileId: RunnerProfileID) async throws -> ScaleSetRecord?
  func updateRegistration(scaleSetId: String, githubScaleSetId: Int64, state: String) async throws

  /// Opens a new session generation for `scaleSetId` (one past the highest existing generation,
  /// starting at 0) and returns it. A new generation per daemon (re)connection is how the message
  /// queue cursor resets without persisting the renewable session secret (spec §45).
  @discardableResult
  func openSession(scaleSetId: String) async throws -> Int
  func currentSession(scaleSetId: String) async throws -> ScaleSetSessionRecord?
  /// Records the GitHub-side session id and lifecycle word for one generation. The session's
  /// bearer token is never persisted (spec §45), only the id that identifies it in a log line.
  func recordSession(
    scaleSetId: String, generation: Int, sessionId: String?, state: String
  ) async throws
  /// Updates `last_message_id` only if `messageId` is greater than the stored cursor — the cursor
  /// never regresses even if messages are delivered out of order.
  func advanceCursor(scaleSetId: String, generation: Int, messageId: Int64) async throws

  /// Idempotent: recording the same `(scaleSetId, generation, messageId)` twice is a no-op.
  func recordIntent(
    scaleSetId: String, generation: Int, messageId: Int64, messageType: String, bodyJson: String
  ) async throws
  func markProcessed(scaleSetId: String, generation: Int, messageId: Int64) async throws
  func markDeleted(scaleSetId: String, generation: Int, messageId: Int64) async throws
  /// `status == .intent` rows for `(scaleSetId, generation)`, ordered by `message_id` ascending.
  func pendingIntents(scaleSetId: String, generation: Int) async throws -> [ScaleSetInboxRecord]
  /// Every inbox row for `scaleSetId`, any generation, ordered by `(generation, message_id)`.
  /// A new session restarts the cursor at 0, so cross-generation duplicate detection has to work
  /// from the semantic ids in these bodies rather than from the cursor (plan C1 "Demand inbox").
  func intents(scaleSetId: String) async throws -> [ScaleSetInboxRecord]
  /// Rewrites one row's `body_json`. Used to fold the ids `AcquireJobs` actually returned into the
  /// intent, so a crash between the acquisition and the acknowledgment does not lose them.
  func updateIntentBody(
    scaleSetId: String, generation: Int, messageId: Int64, bodyJson: String
  ) async throws
}

public final class GRDBScaleSetRepository: ScaleSetRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func ensureScaleSet(profileId: RunnerProfileID, githubScaleSetName: String) async throws -> ScaleSetRecord {
    try await db.write { db in
      if let existing = try ScaleSetRecord.filter(Column("profile_id") == profileId.rawValue).fetchOne(db) {
        return existing
      }
      let now = DatabaseDate.now
      let record = ScaleSetRecord(
        id: String.generateID(), profileId: profileId, githubScaleSetName: githubScaleSetName,
        state: "planned", createdAt: now, updatedAt: now
      )
      try DatabaseErrorMapper.run(entity: "scale_sets") { try record.insert(db) }
      return record
    }
  }

  public func get(profileId: RunnerProfileID) async throws -> ScaleSetRecord? {
    try await db.read { db in
      try ScaleSetRecord.filter(Column("profile_id") == profileId.rawValue).fetchOne(db)
    }
  }

  public func updateRegistration(scaleSetId: String, githubScaleSetId: Int64, state: String) async throws {
    try await db.write { db in
      guard var record = try ScaleSetRecord.fetchOne(db, key: scaleSetId) else {
        throw PersistenceError.notFound(entity: "scale_sets", id: scaleSetId)
      }
      record.githubScaleSetId = githubScaleSetId
      record.state = state
      record.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "scale_sets") { try record.update(db) }
    }
  }

  public func openSession(scaleSetId: String) async throws -> Int {
    try await db.write { db in
      let highest = try Int.fetchOne(
        db,
        sql: "SELECT MAX(session_generation) FROM scale_set_sessions WHERE scale_set_id = ?",
        arguments: [scaleSetId]
      )
      let generation = (highest ?? -1) + 1
      let now = DatabaseDate.now
      let session = ScaleSetSessionRecord(
        scaleSetId: scaleSetId, sessionGeneration: generation, lastMessageId: 0, state: "open",
        createdAt: now, updatedAt: now
      )
      try DatabaseErrorMapper.run(entity: "scale_set_sessions") { try session.insert(db) }
      return generation
    }
  }

  public func currentSession(scaleSetId: String) async throws -> ScaleSetSessionRecord? {
    try await db.read { db in
      try ScaleSetSessionRecord
        .filter(Column("scale_set_id") == scaleSetId)
        .order(Column("session_generation").desc)
        .fetchOne(db)
    }
  }

  public func recordSession(
    scaleSetId: String, generation: Int, sessionId: String?, state: String
  ) async throws {
    try await db.write { db in
      guard var session = try ScaleSetSessionRecord.fetchOne(db, key: [
        "scale_set_id": scaleSetId, "session_generation": generation,
      ]) else {
        throw PersistenceError.notFound(
          entity: "scale_set_sessions", id: "\(scaleSetId)/\(generation)")
      }
      session.sessionId = sessionId ?? session.sessionId
      session.state = state
      session.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "scale_set_sessions") { try session.update(db) }
    }
  }

  public func advanceCursor(scaleSetId: String, generation: Int, messageId: Int64) async throws {
    try await db.write { db in
      guard var session = try ScaleSetSessionRecord.fetchOne(db, key: [
        "scale_set_id": scaleSetId, "session_generation": generation,
      ]) else {
        throw PersistenceError.notFound(entity: "scale_set_sessions", id: "\(scaleSetId)/\(generation)")
      }
      guard messageId > session.lastMessageId else { return }
      session.lastMessageId = messageId
      session.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "scale_set_sessions") { try session.update(db) }
    }
  }

  public func recordIntent(
    scaleSetId: String, generation: Int, messageId: Int64, messageType: String, bodyJson: String
  ) async throws {
    try await db.write { db in
      let now = DatabaseDate.now
      let record = ScaleSetInboxRecord(
        scaleSetId: scaleSetId, sessionGeneration: generation, messageId: messageId, messageType: messageType,
        bodyJson: bodyJson, status: .intent, receivedAt: now, updatedAt: now
      )
      try DatabaseErrorMapper.run(entity: "scale_set_inbox") { try record.insert(db, onConflict: .ignore) }
    }
  }

  public func markProcessed(scaleSetId: String, generation: Int, messageId: Int64) async throws {
    try await setInboxStatus(scaleSetId: scaleSetId, generation: generation, messageId: messageId, status: .processed)
  }

  public func markDeleted(scaleSetId: String, generation: Int, messageId: Int64) async throws {
    try await setInboxStatus(scaleSetId: scaleSetId, generation: generation, messageId: messageId, status: .deleted)
  }

  public func pendingIntents(scaleSetId: String, generation: Int) async throws -> [ScaleSetInboxRecord] {
    try await db.read { db in
      try ScaleSetInboxRecord
        .filter(Column("scale_set_id") == scaleSetId)
        .filter(Column("session_generation") == generation)
        .filter(Column("status") == InboxStatus.intent.rawValue)
        .order(Column("message_id"))
        .fetchAll(db)
    }
  }

  public func intents(scaleSetId: String) async throws -> [ScaleSetInboxRecord] {
    try await db.read { db in
      try ScaleSetInboxRecord
        .filter(Column("scale_set_id") == scaleSetId)
        .order(Column("session_generation"), Column("message_id"))
        .fetchAll(db)
    }
  }

  public func updateIntentBody(
    scaleSetId: String, generation: Int, messageId: Int64, bodyJson: String
  ) async throws {
    try await db.write { db in
      guard var record = try ScaleSetInboxRecord.fetchOne(db, key: [
        "scale_set_id": scaleSetId, "session_generation": generation, "message_id": messageId,
      ]) else {
        throw PersistenceError.notFound(
          entity: "scale_set_inbox", id: "\(scaleSetId)/\(generation)/\(messageId)")
      }
      record.bodyJson = bodyJson
      record.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "scale_set_inbox") { try record.update(db) }
    }
  }

  private func setInboxStatus(scaleSetId: String, generation: Int, messageId: Int64, status: InboxStatus) async throws {
    try await db.write { db in
      guard var record = try ScaleSetInboxRecord.fetchOne(db, key: [
        "scale_set_id": scaleSetId, "session_generation": generation, "message_id": messageId,
      ]) else {
        throw PersistenceError.notFound(entity: "scale_set_inbox", id: "\(scaleSetId)/\(generation)/\(messageId)")
      }
      record.status = status
      record.updatedAt = .now
      try DatabaseErrorMapper.run(entity: "scale_set_inbox") { try record.update(db) }
    }
  }
}
