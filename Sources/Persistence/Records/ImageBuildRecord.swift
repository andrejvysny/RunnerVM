import GRDB
import RunnerCore

/// Mirrors the `image_builds` table (`docs/db_schema_v2.sql`, plus the `recovery_since`
/// column `docs/db_schema_v3.sql` adds).
public struct ImageBuildRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: ImageBuildID
  public var hostId: HostID
  public var name: String?
  public var state: ImageBuildState
  public var operationId: OperationID?
  public var pushReference: String?
  public var pushOperationId: OperationID?
  public var recipePath: String
  public var recipeSHA256: String
  public var contextPath: String
  public var contextSHA256: String?
  /// JSON object of `--build-arg`-style substitutions available to the recipe.
  public var argsJson: String
  public var fromKind: ImageBuildFromKind
  public var fromReference: String
  public var baseDigest: ImageDigest?
  public var baseSHA256: String?
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var diskReservationBytes: UInt64
  public var timeoutMs: Int64
  public var buildPath: String
  public var logPath: String
  public var workerPid: Int32?
  public var workerNonce: String?
  public var totalSteps: Int
  public var currentStep: Int
  public var currentInstruction: String?
  public var imageDigest: ImageDigest?
  public var failureCode: String?
  public var failureMessage: String?
  public var createdAt: DatabaseDate
  public var startedAt: DatabaseDate?
  public var finishedAt: DatabaseDate?
  /// When restart recovery first found this build's builder worker alive-or-unverifiable. `nil`
  /// means "not pending": the build is owned by a live task, or its worker was proven dead. It is
  /// what bounds how long a build nobody can prove dead keeps its capacity, pin and directory.
  public var recoverySince: DatabaseDate?
  public var updatedAt: DatabaseDate

  public init(
    id: ImageBuildID, hostId: HostID, name: String? = nil, state: ImageBuildState,
    operationId: OperationID? = nil, pushReference: String? = nil, pushOperationId: OperationID? = nil,
    recipePath: String, recipeSHA256: String, contextPath: String, contextSHA256: String? = nil,
    argsJson: String = "{}", fromKind: ImageBuildFromKind, fromReference: String,
    baseDigest: ImageDigest? = nil, baseSHA256: String? = nil, cpuCount: Int, memoryBytes: UInt64,
    diskBytes: UInt64, diskReservationBytes: UInt64, timeoutMs: Int64, buildPath: String,
    logPath: String, workerPid: Int32? = nil, workerNonce: String? = nil, totalSteps: Int = 0,
    currentStep: Int = 0, currentInstruction: String? = nil, imageDigest: ImageDigest? = nil,
    failureCode: String? = nil, failureMessage: String? = nil, createdAt: DatabaseDate,
    startedAt: DatabaseDate? = nil, finishedAt: DatabaseDate? = nil,
    recoverySince: DatabaseDate? = nil, updatedAt: DatabaseDate
  ) {
    self.id = id
    self.hostId = hostId
    self.name = name
    self.state = state
    self.operationId = operationId
    self.pushReference = pushReference
    self.pushOperationId = pushOperationId
    self.recipePath = recipePath
    self.recipeSHA256 = recipeSHA256
    self.contextPath = contextPath
    self.contextSHA256 = contextSHA256
    self.argsJson = argsJson
    self.fromKind = fromKind
    self.fromReference = fromReference
    self.baseDigest = baseDigest
    self.baseSHA256 = baseSHA256
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.diskReservationBytes = diskReservationBytes
    self.timeoutMs = timeoutMs
    self.buildPath = buildPath
    self.logPath = logPath
    self.workerPid = workerPid
    self.workerNonce = workerNonce
    self.totalSteps = totalSteps
    self.currentStep = currentStep
    self.currentInstruction = currentInstruction
    self.imageDigest = imageDigest
    self.failureCode = failureCode
    self.failureMessage = failureMessage
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.recoverySince = recoverySince
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "image_builds"

  private enum CodingKeys: String, CodingKey {
    case id, name, state
    case hostId = "host_id"
    case operationId = "operation_id"
    case pushReference = "push_reference"
    case pushOperationId = "push_operation_id"
    case recipePath = "recipe_path"
    case recipeSHA256 = "recipe_sha256"
    case contextPath = "context_path"
    case contextSHA256 = "context_sha256"
    case argsJson = "args_json"
    case fromKind = "from_kind"
    case fromReference = "from_reference"
    case baseDigest = "base_digest"
    case baseSHA256 = "base_sha256"
    case cpuCount = "cpu_count"
    case memoryBytes = "memory_bytes"
    case diskBytes = "disk_bytes"
    case diskReservationBytes = "disk_reservation_bytes"
    case timeoutMs = "timeout_ms"
    case buildPath = "build_path"
    case logPath = "log_path"
    case workerPid = "worker_pid"
    case workerNonce = "worker_nonce"
    case totalSteps = "total_steps"
    case currentStep = "current_step"
    case currentInstruction = "current_instruction"
    case imageDigest = "image_digest"
    case failureCode = "failure_code"
    case failureMessage = "failure_message"
    case createdAt = "created_at"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case recoverySince = "recovery_since"
    case updatedAt = "updated_at"
  }
}
