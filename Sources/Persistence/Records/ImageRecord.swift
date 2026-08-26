import GRDB
import RunnerCore

/// Mirrors the `images` table.
public struct ImageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var digest: ImageDigest
  public var canonicalReference: String?
  public var os: GuestOS
  public var architecture: String
  public var schemaVersion: Int
  public var metadataJson: String
  public var localPath: String
  public var virtualSizeBytes: UInt64
  public var allocatedSizeBytes: UInt64?
  public var runnerVersion: String?
  public var guestAgentVersion: String?
  public var state: ImageState
  public var createdAt: DatabaseDate
  public var pulledAt: DatabaseDate?
  public var lastUsedAt: DatabaseDate?

  public init(
    digest: ImageDigest, canonicalReference: String? = nil, os: GuestOS, architecture: String,
    schemaVersion: Int, metadataJson: String, localPath: String, virtualSizeBytes: UInt64,
    allocatedSizeBytes: UInt64? = nil, runnerVersion: String? = nil, guestAgentVersion: String? = nil,
    state: ImageState, createdAt: DatabaseDate, pulledAt: DatabaseDate? = nil, lastUsedAt: DatabaseDate? = nil
  ) {
    self.digest = digest
    self.canonicalReference = canonicalReference
    self.os = os
    self.architecture = architecture
    self.schemaVersion = schemaVersion
    self.metadataJson = metadataJson
    self.localPath = localPath
    self.virtualSizeBytes = virtualSizeBytes
    self.allocatedSizeBytes = allocatedSizeBytes
    self.runnerVersion = runnerVersion
    self.guestAgentVersion = guestAgentVersion
    self.state = state
    self.createdAt = createdAt
    self.pulledAt = pulledAt
    self.lastUsedAt = lastUsedAt
  }

  public static let databaseTableName = "images"

  private enum CodingKeys: String, CodingKey {
    case digest, os, architecture, state
    case canonicalReference = "canonical_reference"
    case schemaVersion = "schema_version"
    case metadataJson = "metadata_json"
    case localPath = "local_path"
    case virtualSizeBytes = "virtual_size_bytes"
    case allocatedSizeBytes = "allocated_size_bytes"
    case runnerVersion = "runner_version"
    case guestAgentVersion = "guest_agent_version"
    case createdAt = "created_at"
    case pulledAt = "pulled_at"
    case lastUsedAt = "last_used_at"
  }
}
