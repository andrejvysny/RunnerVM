import GRDB
import RunnerCore

/// Mirrors the `job_summaries` table. Low-frequency, append-only telemetry (spec §45 "store
/// low-frequency summary telemetry rather than high-frequency time series").
public struct JobSummaryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: String
  public var runnerSessionId: RunnerSessionID
  public var peakGuestMemoryBytes: UInt64?
  public var averageGuestCPU: Double?
  public var peakWorkerRSSBytes: UInt64?
  public var cloneDurationMs: Int?
  public var bootDurationMs: Int?
  public var agentReadyDurationMs: Int?
  public var jobDurationMs: Int?
  public var createdAt: DatabaseDate

  public init(
    id: String, runnerSessionId: RunnerSessionID, peakGuestMemoryBytes: UInt64? = nil,
    averageGuestCPU: Double? = nil, peakWorkerRSSBytes: UInt64? = nil, cloneDurationMs: Int? = nil,
    bootDurationMs: Int? = nil, agentReadyDurationMs: Int? = nil, jobDurationMs: Int? = nil,
    createdAt: DatabaseDate
  ) {
    self.id = id
    self.runnerSessionId = runnerSessionId
    self.peakGuestMemoryBytes = peakGuestMemoryBytes
    self.averageGuestCPU = averageGuestCPU
    self.peakWorkerRSSBytes = peakWorkerRSSBytes
    self.cloneDurationMs = cloneDurationMs
    self.bootDurationMs = bootDurationMs
    self.agentReadyDurationMs = agentReadyDurationMs
    self.jobDurationMs = jobDurationMs
    self.createdAt = createdAt
  }

  public static let databaseTableName = "job_summaries"

  private enum CodingKeys: String, CodingKey {
    case id
    case runnerSessionId = "runner_session_id"
    case peakGuestMemoryBytes = "peak_guest_memory_bytes"
    case averageGuestCPU = "average_guest_cpu"
    case peakWorkerRSSBytes = "peak_worker_rss_bytes"
    case cloneDurationMs = "clone_duration_ms"
    case bootDurationMs = "boot_duration_ms"
    case agentReadyDurationMs = "agent_ready_duration_ms"
    case jobDurationMs = "job_duration_ms"
    case createdAt = "created_at"
  }
}
