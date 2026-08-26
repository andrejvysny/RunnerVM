import GRDB

/// Mirrors the `audit_events` table. Append-only.
public struct AuditEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: String
  public var kind: String
  public var actor: String
  public var resourceType: String?
  public var resourceId: String?
  public var detailJson: String?
  public var createdAt: DatabaseDate

  public init(
    id: String, kind: String, actor: String, resourceType: String? = nil, resourceId: String? = nil,
    detailJson: String? = nil, createdAt: DatabaseDate
  ) {
    self.id = id
    self.kind = kind
    self.actor = actor
    self.resourceType = resourceType
    self.resourceId = resourceId
    self.detailJson = detailJson
    self.createdAt = createdAt
  }

  public static let databaseTableName = "audit_events"

  private enum CodingKeys: String, CodingKey {
    case id, kind, actor
    case resourceType = "resource_type"
    case resourceId = "resource_id"
    case detailJson = "detail_json"
    case createdAt = "created_at"
  }
}
