import GRDB
import RunnerCore

/// Mirrors the `image_aliases` table (`docs/db_schema_v2.sql`): a mutable, unique local name that
/// resolves to an immutable digest. The name baked into an image's own `manifest.json` never
/// moves; this row is what a rebuild or re-import repoints.
public struct ImageAliasRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var name: String
  public var digest: ImageDigest
  public var updatedAt: DatabaseDate

  public init(name: String, digest: ImageDigest, updatedAt: DatabaseDate) {
    self.name = name
    self.digest = digest
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "image_aliases"

  private enum CodingKeys: String, CodingKey {
    case name, digest
    case updatedAt = "updated_at"
  }
}
