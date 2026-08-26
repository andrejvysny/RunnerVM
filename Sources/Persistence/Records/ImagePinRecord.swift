import GRDB
import RunnerCore

/// Mirrors the `image_pins` table. Composite primary key `(owner_type, owner_id, digest)`; an
/// image with zero rows here is eligible for garbage collection (`ImageRepository.unpinnedImages`).
public struct ImagePinRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var ownerType: ImagePinOwnerType
  public var ownerId: String
  public var digest: ImageDigest
  public var createdAt: DatabaseDate

  public init(ownerType: ImagePinOwnerType, ownerId: String, digest: ImageDigest, createdAt: DatabaseDate) {
    self.ownerType = ownerType
    self.ownerId = ownerId
    self.digest = digest
    self.createdAt = createdAt
  }

  public static let databaseTableName = "image_pins"

  private enum CodingKeys: String, CodingKey {
    case digest
    case ownerType = "owner_type"
    case ownerId = "owner_id"
    case createdAt = "created_at"
  }
}
