import GRDB
import RunnerCore

/// Mirrors the `runner_sessions` table. NEVER add a `jitConfig` property here — see the schema
/// comment above `CREATE TABLE runner_sessions` (spec §45): JIT config carries a one-time runner
/// registration secret and must not be durably persisted.
public struct RunnerSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: RunnerSessionID
  public var instanceId: InstanceID
  public var profileId: RunnerProfileID
  public var jitSource: JitSource
  public var githubRunnerId: Int64?
  public var githubRunnerName: String?
  public var githubJobRequestId: String?
  public var state: RunnerSessionState
  public var jitIssuedAt: DatabaseDate?
  public var jitDeliveredAt: DatabaseDate?
  public var runnerStartedAt: DatabaseDate?
  public var runnerOnlineAt: DatabaseDate?
  public var jobStartedAt: DatabaseDate?
  public var jobFinishedAt: DatabaseDate?
  public var result: String?
  public var failureCode: String?
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    id: RunnerSessionID, instanceId: InstanceID, profileId: RunnerProfileID, jitSource: JitSource,
    githubRunnerId: Int64? = nil, githubRunnerName: String? = nil, githubJobRequestId: String? = nil,
    state: RunnerSessionState, jitIssuedAt: DatabaseDate? = nil, jitDeliveredAt: DatabaseDate? = nil,
    runnerStartedAt: DatabaseDate? = nil, runnerOnlineAt: DatabaseDate? = nil,
    jobStartedAt: DatabaseDate? = nil, jobFinishedAt: DatabaseDate? = nil, result: String? = nil,
    failureCode: String? = nil, createdAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.id = id
    self.instanceId = instanceId
    self.profileId = profileId
    self.jitSource = jitSource
    self.githubRunnerId = githubRunnerId
    self.githubRunnerName = githubRunnerName
    self.githubJobRequestId = githubJobRequestId
    self.state = state
    self.jitIssuedAt = jitIssuedAt
    self.jitDeliveredAt = jitDeliveredAt
    self.runnerStartedAt = runnerStartedAt
    self.runnerOnlineAt = runnerOnlineAt
    self.jobStartedAt = jobStartedAt
    self.jobFinishedAt = jobFinishedAt
    self.result = result
    self.failureCode = failureCode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "runner_sessions"

  private enum CodingKeys: String, CodingKey {
    case id, state, result
    case instanceId = "instance_id"
    case profileId = "profile_id"
    case jitSource = "jit_source"
    case githubRunnerId = "github_runner_id"
    case githubRunnerName = "github_runner_name"
    case githubJobRequestId = "github_job_request_id"
    case jitIssuedAt = "jit_issued_at"
    case jitDeliveredAt = "jit_delivered_at"
    case runnerStartedAt = "runner_started_at"
    case runnerOnlineAt = "runner_online_at"
    case jobStartedAt = "job_started_at"
    case jobFinishedAt = "job_finished_at"
    case failureCode = "failure_code"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
