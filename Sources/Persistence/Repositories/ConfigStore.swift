import Foundation
import GRDB
import RunnerCore

/// Names touched by one `config.apply` (spec §64 step 3). Removal from the document disables the
/// row; nothing is ever deleted, so an operator can restore a profile by putting it back.
public struct ConfigApplyDiff: Codable, Sendable, Hashable {
  public var addedScopes: [String] = []
  public var updatedScopes: [String] = []
  public var disabledScopes: [String] = []
  public var addedProfiles: [String] = []
  public var updatedProfiles: [String] = []
  public var disabledProfiles: [String] = []

  public init() {}

  public var isEmpty: Bool {
    addedScopes.isEmpty && updatedScopes.isEmpty && disabledScopes.isEmpty
      && addedProfiles.isEmpty && updatedProfiles.isEmpty && disabledProfiles.isEmpty
  }
}

public struct ConfigApplyResult: Sendable, Hashable {
  public var diff: ConfigApplyDiff
  public var operationId: OperationID

  public init(diff: ConfigApplyDiff, operationId: OperationID) {
    self.diff = diff
    self.operationId = operationId
  }
}

/// Whole-document desired-state application. Separate from `ScopeRepository`/`ProfileRepository`
/// because an apply must land as one transaction: a half-applied document would leave profiles
/// pointing at scopes that were never written.
public protocol ConfigStore: Sendable {
  func apply(_ config: RunnerConfiguration, actor: String) async throws -> ConfigApplyResult
}

public final class GRDBConfigStore: ConfigStore, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func apply(_ config: RunnerConfiguration, actor: String) async throws -> ConfigApplyResult {
    try await db.write { db in
      var diff = ConfigApplyDiff()
      let now = DatabaseDate.now
      let scopeIds = try Self.applyScopes(config, into: db, now: now, diff: &diff)
      try Self.applyProfiles(config, scopeIds: scopeIds, into: db, now: now, diff: &diff)
      let operation = try Self.recordOperation(db, now: now)
      try Self.recordAudit(db, actor: actor, diff: diff, now: now)
      return ConfigApplyResult(diff: diff, operationId: operation)
    }
  }

  // MARK: - Scopes

  private static func applyScopes(
    _ config: RunnerConfiguration, into db: Database, now: DatabaseDate, diff: inout ConfigApplyDiff
  ) throws -> [String: GitHubScopeID] {
    let existing = try GitHubScopeRecord.fetchAll(db)
    var byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var ids: [String: GitHubScopeID] = [:]
    try DatabaseErrorMapper.run(entity: "github_scopes") {
      for scope in config.github.scopes {
        if let current = byName[scope.name] {
          ids[scope.name] = current.id
          if let updated = Self.merge(scope, into: current, now: now) {
            try updated.update(db)
            diff.updatedScopes.append(scope.name)
          }
        } else {
          let record = GitHubScopeRecord(
            id: .generate(), name: scope.name, kind: scope.kind, owner: scope.owner,
            repository: scope.repository, runnerGroupName: scope.runnerGroup, enabled: true,
            createdAt: now, updatedAt: now)
          try record.insert(db)
          byName[scope.name] = record
          ids[scope.name] = record.id
          diff.addedScopes.append(scope.name)
        }
      }
      let configured = Set(config.github.scopes.map(\.name))
      for var current in existing where !configured.contains(current.name) && current.enabled {
        current.enabled = false
        current.updatedAt = now
        try current.update(db)
        diff.disabledScopes.append(current.name)
      }
    }
    return ids
  }

  /// Returns the row to write, or `nil` when the document changes nothing.
  private static func merge(
    _ scope: GitHubScopeConfig, into current: GitHubScopeRecord, now: DatabaseDate
  ) -> GitHubScopeRecord? {
    var desired = current
    desired.kind = scope.kind
    desired.owner = scope.owner
    desired.repository = scope.repository
    desired.runnerGroupName = scope.runnerGroup
    desired.enabled = true
    // A renamed runner group invalidates the id GitHubControl resolved for the old name.
    if desired.runnerGroupName != current.runnerGroupName { desired.runnerGroupId = nil }
    guard desired != current else { return nil }
    desired.updatedAt = now
    return desired
  }

  // MARK: - Profiles

  private static func applyProfiles(
    _ config: RunnerConfiguration, scopeIds: [String: GitHubScopeID], into db: Database,
    now: DatabaseDate, diff: inout ConfigApplyDiff
  ) throws {
    let existing = try RunnerProfileRecord.fetchAll(db)
    let byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    try DatabaseErrorMapper.run(entity: "runner_profiles") {
      for profile in config.profiles {
        guard let scopeId = scopeIds[profile.scope] else {
          throw PersistenceError.foreignKeyViolated(entity: "runner_profiles", field: "scope_id")
        }
        let desired = try Self.record(
          profile, scopeId: scopeId, existing: byName[profile.name], now: now)
        if let current = byName[profile.name] {
          guard desired != current else { continue }
          var updated = desired
          updated.updatedAt = now
          try updated.update(db)
          diff.updatedProfiles.append(profile.name)
        } else {
          try desired.insert(db)
          diff.addedProfiles.append(profile.name)
        }
      }
      let configured = Set(config.profiles.map(\.name))
      for var current in existing where !configured.contains(current.name) && current.enabled {
        current.enabled = false
        current.updatedAt = now
        try current.update(db)
        diff.disabledProfiles.append(current.name)
      }
    }
  }

  /// Built from `existing` where present so `id`/`createdAt`/`updatedAt` survive an update and the
  /// equality check above only sees document-driven fields.
  private static func record(
    _ profile: RunnerProfileConfig, scopeId: GitHubScopeID, existing: RunnerProfileRecord?,
    now: DatabaseDate
  ) throws -> RunnerProfileRecord {
    RunnerProfileRecord(
      id: existing?.id ?? .generate(),
      name: profile.name,
      scopeId: scopeId,
      imageReference: profile.image,
      guestOS: profile.guestOS,
      lifecycle: profile.lifecycle,
      cpuCount: profile.resources.cpuCount,
      memoryBytes: profile.resources.memoryBytes,
      diskBytes: profile.resources.diskBytes,
      minIdle: profile.warmPool.minIdle,
      maxIdle: profile.warmPool.maxIdle,
      maxInstances: profile.limits.maxInstances,
      sshEnabled: profile.ssh.enabled,
      configJson: try Self.encode(profile),
      enabled: true,
      createdAt: existing?.createdAt ?? now,
      updatedAt: existing?.updatedAt ?? now
    )
  }

  /// Sorted keys so re-applying an unchanged document produces a byte-identical `config_json`.
  private static func encode(_ profile: RunnerProfileConfig) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return String(decoding: try encoder.encode(profile), as: UTF8.self)
    } catch {
      throw PersistenceError.encodingFailed(entity: "runner_profiles.config_json", cause: error)
    }
  }

  // MARK: - Bookkeeping

  private static func recordOperation(_ db: Database, now: DatabaseDate) throws -> OperationID {
    let operation = OperationRecord(
      id: .generate(), kind: "apply-config", resourceType: "config", resourceId: "config",
      state: .succeeded, startedAt: now, finishedAt: now)
    try DatabaseErrorMapper.run(entity: "operations") { try operation.insert(db) }
    return operation.id
  }

  private static func recordAudit(
    _ db: Database, actor: String, diff: ConfigApplyDiff, now: DatabaseDate
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let detail = (try? encoder.encode(diff)).map { String(decoding: $0, as: UTF8.self) }
    let event = AuditEventRecord(
      id: .generateID(), kind: "config.changed", actor: actor, resourceType: "config",
      resourceId: "config", detailJson: detail, createdAt: now)
    try DatabaseErrorMapper.run(entity: "audit_events") { try event.insert(db) }
  }
}
