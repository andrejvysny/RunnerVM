import GRDB

/// Mirrors the `scale_set_inbox` table. Composite primary key `(scale_set_id, session_generation,
/// message_id)` — the natural key for a GitHub Actions message queue message, which is why
/// recording the same message twice is defined as a no-op rather than an error.
public struct ScaleSetInboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var scaleSetId: String
  public var sessionGeneration: Int
  public var messageId: Int64
  public var messageType: String
  public var bodyJson: String
  public var status: InboxStatus
  public var receivedAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    scaleSetId: String, sessionGeneration: Int, messageId: Int64, messageType: String, bodyJson: String,
    status: InboxStatus, receivedAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.scaleSetId = scaleSetId
    self.sessionGeneration = sessionGeneration
    self.messageId = messageId
    self.messageType = messageType
    self.bodyJson = bodyJson
    self.status = status
    self.receivedAt = receivedAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "scale_set_inbox"

  private enum CodingKeys: String, CodingKey {
    case status
    case scaleSetId = "scale_set_id"
    case sessionGeneration = "session_generation"
    case messageId = "message_id"
    case messageType = "message_type"
    case bodyJson = "body_json"
    case receivedAt = "received_at"
    case updatedAt = "updated_at"
  }
}
