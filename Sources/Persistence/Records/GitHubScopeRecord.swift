import GRDB
import RunnerCore

/// Mirrors the `github_scopes` table.
public struct GitHubScopeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: GitHubScopeID
  public var name: String
  public var kind: GitHubScopeKind
  public var owner: String
  public var repository: String?
  public var runnerGroupId: Int64?
  public var runnerGroupName: String?
  public var isPublicRepository: Bool?
  public var enabled: Bool
  /// Free-text health marker (`health TEXT NOT NULL DEFAULT 'unknown'`); GitHubControl owns the
  /// vocabulary, the schema does not CHECK-constrain it.
  public var health: String
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    id: GitHubScopeID, name: String, kind: GitHubScopeKind, owner: String, repository: String? = nil,
    runnerGroupId: Int64? = nil, runnerGroupName: String? = nil, isPublicRepository: Bool? = nil,
    enabled: Bool = true, health: String = "unknown", createdAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.owner = owner
    self.repository = repository
    self.runnerGroupId = runnerGroupId
    self.runnerGroupName = runnerGroupName
    self.isPublicRepository = isPublicRepository
    self.enabled = enabled
    self.health = health
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "github_scopes"

  private enum CodingKeys: String, CodingKey {
    case id, name, kind, owner, repository, enabled, health
    case runnerGroupId = "runner_group_id"
    case runnerGroupName = "runner_group_name"
    case isPublicRepository = "is_public_repository"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
