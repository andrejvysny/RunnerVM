import DaemonAPI
import Foundation
import Persistence
import RunnerCore

/// Turns a validated `RunnerConfiguration` into persisted desired state (spec §64 steps 3-4) and
/// keeps the applied document on disk so `config.get` survives a restart.
public struct ConfigApplier: Sendable {
  public struct Outcome: Sendable {
    public var diff: ConfigDiff
    public var operationId: OperationID
    public var appliedAt: Date
    public var yaml: String
  }

  public static let fileName = "config.yaml"

  private let store: any ConfigStore
  private let stateDir: URL

  public init(store: any ConfigStore, stateDir: URL) {
    self.store = store
    self.stateDir = stateDir
  }

  public var appliedConfigURL: URL { stateDir.appending(path: Self.fileName) }

  /// The database transaction runs first: a failed write must not leave a `config.yaml` claiming
  /// state that was never persisted.
  public func apply(
    _ config: RunnerConfiguration, yaml: String, actor: String
  ) async throws -> Outcome {
    let result = try await store.apply(config, actor: actor)
    let url = appliedConfigURL
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try Data(yaml.utf8).write(to: url, options: .atomic)
    let appliedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? Date()
    return Outcome(
      diff: Self.map(result.diff), operationId: result.operationId, appliedAt: appliedAt,
      yaml: yaml)
  }

  /// The last applied document, if this host has ever applied one.
  public func loadApplied() -> (yaml: String, appliedAt: Date)? {
    let url = appliedConfigURL
    guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let appliedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? Date()
    return (yaml, appliedAt)
  }

  private static func map(_ diff: ConfigApplyDiff) -> ConfigDiff {
    ConfigDiff(
      addedScopes: diff.addedScopes,
      updatedScopes: diff.updatedScopes,
      disabledScopes: diff.disabledScopes,
      addedProfiles: diff.addedProfiles,
      updatedProfiles: diff.updatedProfiles,
      disabledProfiles: diff.disabledProfiles)
  }
}
