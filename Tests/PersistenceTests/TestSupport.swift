import Foundation
import RunnerCore
import Testing
@testable import Persistence

/// Every test gets its own throwaway database file (`RunnerDatabase.inMemory()`), deleted when the
/// `RunnerDatabase` instance is deallocated — no shared state, no sleeping between tests.
enum TestDatabase {
  static func make() throws -> RunnerDatabase { try RunnerDatabase.inMemory() }
}

/// Minimal, FK-valid fixtures for the `host -> github_scopes -> runner_profiles -> images ->
/// instances -> runner_sessions` chain, so each repository test only has to override what it's
/// actually testing.
enum Fixtures {
  static let hostID = HostID(rawValue: "test-host")

  static func scope(name: String = "acme") -> GitHubScopeRecord {
    GitHubScopeRecord(
      id: GitHubScopeID.generate(), name: name, kind: .organization, owner: "acme",
      createdAt: .now, updatedAt: .now
    )
  }

  static func profile(name: String = "linux-default", scopeId: GitHubScopeID) -> RunnerProfileRecord {
    RunnerProfileRecord(
      id: RunnerProfileID.generate(), name: name, scopeId: scopeId,
      imageReference: "ghcr.io/acme/ubuntu-24:latest", guestOS: .linux, lifecycle: .ephemeral,
      cpuCount: 4, memoryBytes: 8_000_000_000, diskBytes: 80_000_000_000,
      configJson: "{}", createdAt: .now, updatedAt: .now
    )
  }

  static func image(digest: String = "sha256:\(String(repeating: "a", count: 64))") -> ImageRecord {
    ImageRecord(
      digest: ImageDigest(rawValue: digest), os: .linux, architecture: "arm64", schemaVersion: 1,
      metadataJson: "{}", localPath: "/var/lib/runnervm/images/\(digest)", virtualSizeBytes: 1_000_000_000,
      state: .ready, createdAt: .now
    )
  }

  static func instance(profileId: RunnerProfileID, imageDigest: ImageDigest, hostId: HostID = hostID) -> InstanceRecord {
    InstanceRecord(
      id: InstanceID.generate(), profileId: profileId, imageDigest: imageDigest, hostId: hostId,
      name: "rvm-test-\(UUID().uuidString.prefix(6))", lifecycle: .ephemeral, state: .planned,
      desiredState: .idle, cpuCount: 4, memoryBytes: 8_000_000_000, diskBytes: 80_000_000_000,
      diskReservationBytes: 80_000_000_000, instancePath: "/var/lib/runnervm/instances/test",
      createdAt: .now
    )
  }

  static func runnerSession(instanceId: InstanceID, profileId: RunnerProfileID) -> RunnerSessionRecord {
    RunnerSessionRecord(
      id: RunnerSessionID.generate(), instanceId: instanceId, profileId: profileId, jitSource: .scaleSet,
      state: .planned, createdAt: .now, updatedAt: .now
    )
  }

  /// Inserts host + scope + profile + image and returns the ids needed to build an instance.
  @discardableResult
  static func seedProfileChain(db: RunnerDatabase) async throws -> (
    hostId: HostID, scopeId: GitHubScopeID, profileId: RunnerProfileID, digest: ImageDigest
  ) {
    try await GRDBHostRepository(db: db).ensureHost(id: hostID)
    let scopeRecord = scope()
    try await GRDBScopeRepository(db: db).upsert(scopeRecord)
    let profileRecord = profile(scopeId: scopeRecord.id)
    try await GRDBProfileRepository(db: db).upsert(profileRecord)
    let imageRecord = image()
    try await GRDBImageRepository(db: db).upsert(imageRecord)
    return (hostID, scopeRecord.id, profileRecord.id, imageRecord.digest)
  }
}
