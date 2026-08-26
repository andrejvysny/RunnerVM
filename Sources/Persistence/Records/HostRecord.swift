import GRDB
import RunnerCore

/// Mirrors the `host` table (`docs/db_schema_v1.sql`). One row per host; v1 has exactly one.
public struct HostRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: HostID
  public var mode: HostMode
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(id: HostID, mode: HostMode, createdAt: DatabaseDate, updatedAt: DatabaseDate) {
    self.id = id
    self.mode = mode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "host"

  private enum CodingKeys: String, CodingKey {
    case id, mode
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
