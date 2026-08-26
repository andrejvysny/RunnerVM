import Foundation
import GRDB
import RunnerCore

/// Mirrors the `runner_profiles` table. `configJson` is the JSON-encoded `RunnerProfileConfig`
/// (spec §10); repositories do not decode it, callers do via `RunnerProfileRecord.decodedConfig`.
public struct RunnerProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var id: RunnerProfileID
  public var name: String
  public var scopeId: GitHubScopeID
  public var imageReference: String
  public var guestOS: GuestOS
  public var lifecycle: InstanceLifecycle
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var minIdle: Int
  public var maxIdle: Int
  public var maxInstances: Int?
  public var sshEnabled: Bool
  public var configJson: String
  public var enabled: Bool
  public var createdAt: DatabaseDate
  public var updatedAt: DatabaseDate

  public init(
    id: RunnerProfileID, name: String, scopeId: GitHubScopeID, imageReference: String, guestOS: GuestOS,
    lifecycle: InstanceLifecycle, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
    minIdle: Int = 0, maxIdle: Int = 0, maxInstances: Int? = nil, sshEnabled: Bool = true,
    configJson: String, enabled: Bool = true, createdAt: DatabaseDate, updatedAt: DatabaseDate
  ) {
    self.id = id
    self.name = name
    self.scopeId = scopeId
    self.imageReference = imageReference
    self.guestOS = guestOS
    self.lifecycle = lifecycle
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.minIdle = minIdle
    self.maxIdle = maxIdle
    self.maxInstances = maxInstances
    self.sshEnabled = sshEnabled
    self.configJson = configJson
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "runner_profiles"

  private enum CodingKeys: String, CodingKey {
    case id, name, lifecycle, enabled
    case scopeId = "scope_id"
    case imageReference = "image_reference"
    case guestOS = "guest_os"
    case cpuCount = "cpu_count"
    case memoryBytes = "memory_bytes"
    case diskBytes = "disk_bytes"
    case minIdle = "min_idle"
    case maxIdle = "max_idle"
    case maxInstances = "max_instances"
    case sshEnabled = "ssh_enabled"
    case configJson = "config_json"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

extension RunnerProfileRecord {
  /// Decodes `configJson` back into `RunnerProfileConfig`. Throws `PersistenceError.encodingFailed`
  /// rather than a raw `DecodingError` so callers only need to handle `RunnerError`.
  public func decodedConfig() throws -> RunnerProfileConfig {
    do {
      return try JSONDecoder().decode(RunnerProfileConfig.self, from: Data(configJson.utf8))
    } catch {
      throw PersistenceError.encodingFailed(entity: "runner_profiles.config_json", cause: error)
    }
  }
}
