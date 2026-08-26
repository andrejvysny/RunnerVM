import GRDB
import RunnerCore

/// Mirrors the `operations` table (spec §45 "useful for reconciliation/debugging").
public struct OperationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: OperationID
  /// Free text, e.g. `pull-image`, `clone-instance`, `boot-instance`, `issue-jit`,
  /// `destroy-instance`, `reconcile` (spec §45 examples).
  public var kind: String
  public var resourceType: String
  public var resourceId: String
  public var state: OperationState
  public var idempotencyKey: String?
  public var startedAt: DatabaseDate
  public var finishedAt: DatabaseDate?
  public var errorCode: String?
  public var errorMessage: String?
  public var metadataJson: String?

  public init(
    id: OperationID, kind: String, resourceType: String, resourceId: String, state: OperationState,
    idempotencyKey: String? = nil, startedAt: DatabaseDate, finishedAt: DatabaseDate? = nil,
    errorCode: String? = nil, errorMessage: String? = nil, metadataJson: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.resourceType = resourceType
    self.resourceId = resourceId
    self.state = state
    self.idempotencyKey = idempotencyKey
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.errorCode = errorCode
    self.errorMessage = errorMessage
    self.metadataJson = metadataJson
  }

  public static let databaseTableName = "operations"

  private enum CodingKeys: String, CodingKey {
    case id, kind, state
    case resourceType = "resource_type"
    case resourceId = "resource_id"
    case idempotencyKey = "idempotency_key"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case errorCode = "error_code"
    case errorMessage = "error_message"
    case metadataJson = "metadata_json"
  }
}
