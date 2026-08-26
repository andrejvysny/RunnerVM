// Ported from github.com/actions/scaleset@v0.4.0 (MIT) client.go — see PROVENANCE.md.

import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Native Swift implementation of the GitHub Actions runner-scale-set control plane (spec §50, §51).
///
/// A port of the subset of `github.com/actions/scaleset` RunnerVM needs, not a wrapper around it:
/// the Go client is the reference for the wire protocol only. Everything scale-set-specific stops
/// at `ScaleSetControlPlane`, so the preview API can change without touching the scheduler.
///
/// One `ActionsServiceConnection` — and therefore one admin-token lifecycle — is kept per scope.
public actor ActionsScaleSetClient: ScaleSetControlPlane {
  private let http: GitHubHTTPClient
  private let apiBaseURL: URL
  private let configBaseURL: URL
  private let session: URLSession
  private let systemInfo: ActionsSystemInfo
  private let options: ActionsServiceOptions
  private let logger: Logger
  private let retry: ActionsRetry
  private let now: @Sendable () -> Date

  private var connections: [GitHubScope: ActionsServiceConnection] = [:]

  public init(
    http: GitHubHTTPClient,
    apiBaseURL: URL = GitHubHTTPClient.defaultBaseURL,
    configBaseURL: URL? = nil,
    session: URLSession = .shared,
    systemInfo: ActionsSystemInfo = ActionsSystemInfo(),
    options: ActionsServiceOptions = ActionsServiceOptions(),
    logger: Logger = Logger(component: .github),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.http = http
    self.apiBaseURL = apiBaseURL
    self.configBaseURL = configBaseURL ?? ActionsConfigURL.base(fromAPIBaseURL: apiBaseURL)
    self.session = session
    self.systemInfo = systemInfo
    self.options = options
    self.logger = logger
    retry = ActionsRetry(policy: options.retryPolicy, sleep: sleep, random: random)
    self.now = now
  }

  // MARK: - Scale sets

  /// Converges the scale set on GitHub with what the profile asks for: create it when missing,
  /// patch it when the labels or the runner settings drifted, otherwise leave it alone.
  public func ensureScaleSet(
    scope: GitHubScope, name: String, runnerGroupID: Int64, labels: [String], disableUpdate: Bool
  ) async throws -> ScaleSetInfo {
    let desired = labels.isEmpty ? [name] : labels
    guard let existing = try await fetch(scope: scope, runnerGroupID: runnerGroupID, name: name) else {
      return try await createScaleSet(
        scope: scope, name: name, runnerGroupID: runnerGroupID, labels: desired,
        disableUpdate: disableUpdate
      )
    }
    let current = try existing.domain(context: "scale set \(name)")
    guard needsUpdate(existing, labels: desired, disableUpdate: disableUpdate) else { return current }
    return try await updateScaleSet(
      scope: scope, id: current.id, name: name, runnerGroupID: runnerGroupID, labels: desired,
      disableUpdate: disableUpdate
    )
  }

  public func getScaleSet(
    scope: GitHubScope, runnerGroupID: Int64, name: String
  ) async throws -> ScaleSetInfo? {
    try await fetch(scope: scope, runnerGroupID: runnerGroupID, name: name)?
      .domain(context: "scale set \(name)")
  }

  /// By id, for a scale set whose id is already stored (spec §2201 `scale_sets`).
  public func getScaleSet(scope: GitHubScope, id: Int64) async throws -> ScaleSetInfo? {
    let label = "GET \(ActionsEndpoint.scaleSet(id))"
    do {
      return try await connection(for: scope).send(
        method: "GET", path: ActionsEndpoint.scaleSet(id), idempotent: true,
        as: ActionsWire.RunnerScaleSet.self, label: label
      ).domain(context: label)
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      return nil
    }
  }

  public func deleteScaleSet(scope: GitHubScope, id: Int64) async throws {
    do {
      try await connection(for: scope).sendExpectingNoContent(
        method: "DELETE", path: ActionsEndpoint.scaleSet(id), idempotent: true,
        label: "DELETE \(ActionsEndpoint.scaleSet(id))"
      )
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      logger.debug("scale set already absent", metadata: ["scale_set_id": .stringConvertible(id)])
    }
  }

  /// `GET /_apis/runtime/runnergroups?groupName=…`. Resolves the id a scale set is created in.
  public func runnerGroupID(scope: GitHubScope, name: String) async throws -> Int64 {
    let label = "GET \(ActionsEndpoint.runnerGroups)"
    let list = try await connection(for: scope).send(
      method: "GET", path: ActionsEndpoint.runnerGroups,
      query: [URLQueryItem(name: "groupName", value: name)], idempotent: true,
      as: ActionsWire.RunnerGroupList.self, label: label
    )
    let groups = list.value ?? []
    guard groups.count == 1, let id = groups[0].id else {
      throw groups.isEmpty
        ? GitHubControlError.notFound(resource: "runner group '\(name)' in \(scope.description)")
        : GitHubControlError.invalidResponse(
          reason: "\(label): \(groups.count) runner groups named '\(name)'"
        )
    }
    return id
  }

  // MARK: - Sessions

  public func openSession(
    scope: GitHubScope, scaleSetID: Int64, owner: String
  ) async throws -> any ScaleSetSession {
    let connection = connection(for: scope)
    let label = "POST \(ActionsEndpoint.sessions(scaleSetID))"
    let body = try ActionsURL.encode(["ownerName": owner], label: label)
    let created = try await connection.send(
      method: "POST", path: ActionsEndpoint.sessions(scaleSetID), body: body, idempotent: false,
      as: ActionsWire.Session.self, label: label
    )
    return try ActionsMessageSession(
      connection: connection, scaleSetID: scaleSetID, owner: owner, session: created,
      options: options, logger: logger
    )
  }

  // MARK: - Runners

  /// Scale-set JIT config: the runner is bound to the scale set, and GitHub picks the job.
  /// Never retried — a repeat that the service already processed leaves an orphan registration.
  public func generateJITConfig(
    scope: GitHubScope, scaleSetID: Int64, runnerName: String, workFolder: String
  ) async throws -> JITRunnerConfig {
    let path = ActionsEndpoint.jitConfig(scaleSetID)
    let label = "POST \(path)"
    let body = try ActionsURL.encode(
      ActionsWire.JitRunnerSetting(name: runnerName, workFolder: workFolder), label: label
    )
    let response = try await connection(for: scope).send(
      method: "POST", path: path, body: body, idempotent: false,
      as: ActionsWire.JitRunnerConfig.self, label: label
    )
    guard let runner = try response.runner?.domain(context: label) else {
      throw GitHubControlError.jitGenerationFailed(
        reason: "\(label): the Actions service returned no runner for \(runnerName)"
      )
    }
    guard let encoded = response.encodedJITConfig, !encoded.isEmpty else {
      throw GitHubControlError.jitGenerationFailed(
        reason: "\(label): the Actions service returned an empty JIT config for \(runnerName)"
      )
    }
    // The config itself is a secret and never reaches a log line (spec §36).
    logger.info(
      "generated scale-set JIT runner config",
      metadata: [
        "scope": .string(scope.description), "scale_set_id": .stringConvertible(scaleSetID),
        "runner_id": .stringConvertible(runner.id), "runner_name": .string(runner.name),
      ]
    )
    return JITRunnerConfig(runnerID: runner.id, runnerName: runner.name, encodedJITConfig: encoded)
  }

  public func runner(scope: GitHubScope, id: Int64) async throws -> ScaleSetRunnerReference? {
    let label = "GET \(ActionsEndpoint.runner(id))"
    do {
      return try await connection(for: scope).send(
        method: "GET", path: ActionsEndpoint.runner(id), idempotent: true,
        as: ActionsWire.RunnerReference.self, label: label
      ).domain(context: label)
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      return nil
    }
  }

  public func runner(scope: GitHubScope, name: String) async throws -> ScaleSetRunnerReference? {
    let label = "GET \(ActionsEndpoint.runners)"
    let list = try await connection(for: scope).send(
      method: "GET", path: ActionsEndpoint.runners,
      query: [URLQueryItem(name: "agentName", value: name)], idempotent: true,
      as: ActionsWire.RunnerReferenceList.self, label: label
    )
    let runners = list.value ?? []
    guard runners.count <= 1 else {
      throw GitHubControlError.invalidResponse(reason: "\(label): \(runners.count) runners named '\(name)'")
    }
    return try runners.first?.domain(context: label)
  }

  /// Idempotent: a scale-set runner deletes itself after one job, so teardown routinely races it.
  public func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws {
    do {
      try await connection(for: scope).sendExpectingNoContent(
        method: "DELETE", path: ActionsEndpoint.runner(runnerID), idempotent: true,
        label: "DELETE \(ActionsEndpoint.runner(runnerID))"
      )
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      logger.debug(
        "scale-set runner already absent",
        metadata: ["scope": .string(scope.description), "runner_id": .stringConvertible(runnerID)]
      )
    }
  }

  // MARK: - Internals

  private func connection(for scope: GitHubScope) -> ActionsServiceConnection {
    if let existing = connections[scope] { return existing }
    let created = ActionsServiceConnection(
      scope: scope, http: http, apiBaseURL: apiBaseURL, configBaseURL: configBaseURL,
      session: session, systemInfo: systemInfo, options: options, logger: logger, retry: retry,
      now: now
    )
    connections[scope] = created
    return created
  }

  private func fetch(
    scope: GitHubScope, runnerGroupID: Int64, name: String
  ) async throws -> ActionsWire.RunnerScaleSet? {
    let label = "GET \(ActionsEndpoint.scaleSets)"
    let list = try await connection(for: scope).send(
      method: "GET", path: ActionsEndpoint.scaleSets,
      query: [
        URLQueryItem(name: "runnerGroupId", value: String(runnerGroupID)),
        URLQueryItem(name: "name", value: name),
      ],
      idempotent: true, as: ActionsWire.RunnerScaleSetList.self, label: label
    )
    let found = list.value ?? []
    guard found.count <= 1 else {
      throw GitHubControlError.invalidResponse(
        reason: "\(label): \(found.count) scale sets named '\(name)' in group \(runnerGroupID)"
      )
    }
    return found.first
  }

  private func createScaleSet(
    scope: GitHubScope, name: String, runnerGroupID: Int64, labels: [String], disableUpdate: Bool
  ) async throws -> ScaleSetInfo {
    let label = "POST \(ActionsEndpoint.scaleSets)"
    let created = try await connection(for: scope).send(
      method: "POST", path: ActionsEndpoint.scaleSets,
      body: try body(name: name, runnerGroupID: runnerGroupID, labels: labels,
                     disableUpdate: disableUpdate, label: label),
      idempotent: false, as: ActionsWire.RunnerScaleSet.self, label: label
    )
    logger.info(
      "created runner scale set",
      metadata: ["scope": .string(scope.description), "scale_set_name": .string(name)]
    )
    return try created.domain(context: label)
  }

  private func updateScaleSet(
    scope: GitHubScope, id: Int64, name: String, runnerGroupID: Int64, labels: [String],
    disableUpdate: Bool
  ) async throws -> ScaleSetInfo {
    let label = "PATCH \(ActionsEndpoint.scaleSet(id))"
    let updated = try await connection(for: scope).send(
      method: "PATCH", path: ActionsEndpoint.scaleSet(id),
      body: try body(name: name, runnerGroupID: runnerGroupID, labels: labels,
                     disableUpdate: disableUpdate, label: label),
      idempotent: false, as: ActionsWire.RunnerScaleSet.self, label: label
    )
    logger.info(
      "updated runner scale set",
      metadata: ["scope": .string(scope.description), "scale_set_name": .string(name)]
    )
    return try updated.domain(context: label)
  }

  private func body(
    name: String, runnerGroupID: Int64, labels: [String], disableUpdate: Bool, label: String
  ) throws -> Data {
    // Every label carries type "System": that is the only type the scale-set API accepts, and the
    // Go client fills it in for callers too.
    try ActionsURL.encode(
      ActionsWire.RunnerScaleSet(
        name: name, runnerGroupId: runnerGroupID,
        labels: labels.map { ActionsWire.Label(type: "System", name: $0) },
        runnerSetting: ActionsWire.RunnerSetting(disableUpdate: disableUpdate)
      ),
      label: label
    )
  }

  /// Labels are compared case-insensitively as a set: GitHub matches `runs-on` that way, and the
  /// service is free to reorder them.
  private func needsUpdate(
    _ existing: ActionsWire.RunnerScaleSet, labels: [String], disableUpdate: Bool
  ) -> Bool {
    let current = Set((existing.labels ?? []).map { $0.name.lowercased() })
    if current != Set(labels.map { $0.lowercased() }) { return true }
    return (existing.runnerSetting?.disableUpdate ?? false) != disableUpdate
  }
}
