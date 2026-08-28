import GRDB
import RunnerCore

/// Mirrors the `instances` table. Note there is no `updated_at` column here (unlike
/// `runner_sessions`/`scale_sets`/`host`/`runner_profiles`/`github_scopes`) — every mutation has
/// its own purpose-built timestamp column (`started_at`, `stopped_at`, `last_seen_at`, ...), so
/// `InstanceRepository.transition` does not invent one.
public struct InstanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: InstanceID
  public var profileId: RunnerProfileID
  public var imageDigest: ImageDigest
  public var hostId: HostID
  public var name: String
  public var lifecycle: InstanceLifecycle
  public var state: InstanceState
  public var desiredState: InstanceState
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var diskReservationBytes: UInt64
  public var workerPid: Int32?
  public var workerGeneration: Int
  public var incarnationNonce: String?
  public var specDigest: String?
  public var workerSocket: String?
  public var macAddress: String?
  public var machineIdentifier: String?
  public var bootId: String?
  public var tainted: Bool
  public var taintReason: String?
  public var jobsConsumed: Int
  public var retireAfterSession: Bool
  public var hardDeadlineAt: DatabaseDate?
  public var instancePath: String
  public var createdAt: DatabaseDate
  public var startedAt: DatabaseDate?
  public var agentReadyAt: DatabaseDate?
  public var stoppedAt: DatabaseDate?
  public var deletedAt: DatabaseDate?
  public var lastSeenAt: DatabaseDate?
  public var failureCode: String?
  public var failureMessage: String?
  public var purpose: InstancePurpose
  public var pinnedUntil: DatabaseDate?

  public init(
    id: InstanceID, profileId: RunnerProfileID, imageDigest: ImageDigest, hostId: HostID, name: String,
    lifecycle: InstanceLifecycle, state: InstanceState, desiredState: InstanceState, cpuCount: Int,
    memoryBytes: UInt64, diskBytes: UInt64, diskReservationBytes: UInt64, workerPid: Int32? = nil,
    workerGeneration: Int = 0, incarnationNonce: String? = nil, specDigest: String? = nil,
    workerSocket: String? = nil, macAddress: String? = nil, machineIdentifier: String? = nil,
    bootId: String? = nil, tainted: Bool = false, taintReason: String? = nil, jobsConsumed: Int = 0,
    retireAfterSession: Bool = false, hardDeadlineAt: DatabaseDate? = nil, instancePath: String,
    createdAt: DatabaseDate, startedAt: DatabaseDate? = nil, agentReadyAt: DatabaseDate? = nil,
    stoppedAt: DatabaseDate? = nil, deletedAt: DatabaseDate? = nil, lastSeenAt: DatabaseDate? = nil,
    failureCode: String? = nil, failureMessage: String? = nil, purpose: InstancePurpose = .runner,
    pinnedUntil: DatabaseDate? = nil
  ) {
    self.id = id
    self.profileId = profileId
    self.imageDigest = imageDigest
    self.hostId = hostId
    self.name = name
    self.lifecycle = lifecycle
    self.state = state
    self.desiredState = desiredState
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.diskReservationBytes = diskReservationBytes
    self.workerPid = workerPid
    self.workerGeneration = workerGeneration
    self.incarnationNonce = incarnationNonce
    self.specDigest = specDigest
    self.workerSocket = workerSocket
    self.macAddress = macAddress
    self.machineIdentifier = machineIdentifier
    self.bootId = bootId
    self.tainted = tainted
    self.taintReason = taintReason
    self.jobsConsumed = jobsConsumed
    self.retireAfterSession = retireAfterSession
    self.hardDeadlineAt = hardDeadlineAt
    self.instancePath = instancePath
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.agentReadyAt = agentReadyAt
    self.stoppedAt = stoppedAt
    self.deletedAt = deletedAt
    self.lastSeenAt = lastSeenAt
    self.failureCode = failureCode
    self.failureMessage = failureMessage
    self.purpose = purpose
    self.pinnedUntil = pinnedUntil
  }

  public static let databaseTableName = "instances"

  private enum CodingKeys: String, CodingKey {
    case id, name, lifecycle, state, tainted
    case profileId = "profile_id"
    case imageDigest = "image_digest"
    case hostId = "host_id"
    case desiredState = "desired_state"
    case cpuCount = "cpu_count"
    case memoryBytes = "memory_bytes"
    case diskBytes = "disk_bytes"
    case diskReservationBytes = "disk_reservation_bytes"
    case workerPid = "worker_pid"
    case workerGeneration = "worker_generation"
    case incarnationNonce = "incarnation_nonce"
    case specDigest = "spec_digest"
    case workerSocket = "worker_socket"
    case macAddress = "mac_address"
    case machineIdentifier = "machine_identifier"
    case bootId = "boot_id"
    case taintReason = "taint_reason"
    case jobsConsumed = "jobs_consumed"
    case retireAfterSession = "retire_after_session"
    case hardDeadlineAt = "hard_deadline_at"
    case instancePath = "instance_path"
    case createdAt = "created_at"
    case startedAt = "started_at"
    case agentReadyAt = "agent_ready_at"
    case stoppedAt = "stopped_at"
    case deletedAt = "deleted_at"
    case lastSeenAt = "last_seen_at"
    case failureCode = "failure_code"
    case failureMessage = "failure_message"
    case purpose
    case pinnedUntil = "pinned_until"
  }
}
