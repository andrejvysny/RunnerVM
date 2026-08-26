import GRDB
import RunnerCore

/// Mirrors the `scale_sets` table. One row per `RunnerProfileRecord` (`profile_id` is `UNIQUE`).
public struct ScaleSetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: String
  public var profileId: RunnerProfileID
  public var githubScaleSetId: Int64?
  public var githubScaleSetName: String
  /// Free text (`state TEXT NOT NULL`, no CHECK) — owned by `ScaleSetController`, not a
  /// `StateMachineState` in RunnerCore.
  public var state: String
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    id: String, profileId: RunnerProfileID, githubScaleSetId: Int64? = nil, githubScaleSetName: String,
    state: String, createdAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.id = id
    self.profileId = profileId
    self.githubScaleSetId = githubScaleSetId
    self.githubScaleSetName = githubScaleSetName
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "scale_sets"

  private enum CodingKeys: String, CodingKey {
    case id, state
    case profileId = "profile_id"
    case githubScaleSetId = "github_scale_set_id"
    case githubScaleSetName = "github_scale_set_name"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
