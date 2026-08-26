import GRDB

/// Mirrors the `scale_set_sessions` table. Composite primary key `(scale_set_id,
/// session_generation)`: each daemon (re)connection to the GitHub message queue opens a new
/// generation instead of persisting the renewable session bearer secret across restarts (spec §45
/// "prefer re-establishing sessions after daemon restart").
public struct ScaleSetSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var scaleSetId: String
  public var sessionGeneration: Int
  public var sessionId: String?
  public var lastMessageId: Int64
  /// Free text (`state TEXT NOT NULL`, no CHECK) — no formal state machine in the spec.
  public var state: String
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    scaleSetId: String, sessionGeneration: Int, sessionId: String? = nil, lastMessageId: Int64 = 0,
    state: String, createdAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.scaleSetId = scaleSetId
    self.sessionGeneration = sessionGeneration
    self.sessionId = sessionId
    self.lastMessageId = lastMessageId
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "scale_set_sessions"

  private enum CodingKeys: String, CodingKey {
    case state
    case scaleSetId = "scale_set_id"
    case sessionGeneration = "session_generation"
    case sessionId = "session_id"
    case lastMessageId = "last_message_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
