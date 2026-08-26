import DaemonAPI
import Foundation
import Persistence
import RPC
import RunnerCore
import RunnerLogging

/// `auth.*`, `github.test`, `runner.*` and `debug.runJit` (spec §12, §148).
///
/// Split out of `DaemonServiceImpl.swift` to keep that file under its line budget; every member
/// runs actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  // MARK: - runner.*

  func runnerList() async throws -> RunnerListResponse {
    let names = try await profileNames()
    let records = try await runners.list()
    return RunnerListResponse(
      sessions: records.map {
        GitHubMapping.session($0, profile: names[$0.profileId] ?? $0.profileId.rawValue)
      })
  }

  func runnerGet(_ request: RunnerGetRequest) async throws -> RunnerSessionDTO {
    let record = try await runners.get(id: RunnerSessionID(rawValue: request.sessionId))
    let names = try await profileNames()
    return GitHubMapping.session(
      record, profile: names[record.profileId] ?? record.profileId.rawValue)
  }

  // MARK: - auth.*

  func authStatus() async throws -> AuthStatus {
    await gateway.snapshot()
  }

  /// The token reaches the daemon only over the peer-checked Unix socket and is written straight
  /// to the configured store; it is never logged, echoed back or copied into the applied YAML
  /// (spec §12, §129, §140).
  func authLogin(_ request: AuthLoginRequest) async throws -> AuthLoginResponse {
    let response = try await gateway.login(token: request.token)
    logger.notice(
      "github auth changed",
      metadata: ["action": .string("login"), "location": .string(response.location)])
    try? await audit.record(
      kind: "auth.changed", actor: actorName, resourceType: "github", resourceId: "credential",
      detail: JSONValue.object([
        "action": .string("login"), "location": .string(response.location),
      ]).encodedString())
    return response
  }

  func authLogout() async throws -> AuthLogoutResponse {
    let response = try await gateway.logout()
    logger.notice(
      "github auth changed",
      metadata: ["action": .string("logout"), "location": .string(response.location)])
    try? await audit.record(
      kind: "auth.changed", actor: actorName, resourceType: "github", resourceId: "credential",
      detail: JSONValue.object([
        "action": .string("logout"), "removed": .bool(response.removed),
      ]).encodedString())
    return response
  }

  /// The one call that deliberately talks to GitHub: credential first, then every configured
  /// scope's permissions, runner group and visibility (spec §148).
  func githubTest() async throws -> GitHubTestResponse {
    let auth = await gateway.probe()
    return GitHubTestResponse(auth: auth, scopes: await scopeHealth.refresh())
  }

  // MARK: - debug.runJit

  /// Spec §148: prove authentication, JIT generation, secret delivery, runner lifecycle and
  /// cleanup end to end without waiting for the scheduler to want capacity.
  func debugRunJIT(_ request: DebugRunJITRequest) async throws -> DebugRunJITResponse {
    guard let profileRow = try await profiles.get(name: request.profile) else {
      throw DaemonServiceError.notFound(entity: "profile", name: request.profile)
    }
    // Checked before the image is resolved: an unhealthy scope must not cost a VM boot.
    try await runners.assertSchedulable(profile: profileRow)
    let profile = try profileRow.decodedConfig()
    var created = false
    var instanceId: InstanceID
    if let idle = try await instanceRows.list(profile: profileRow.id, states: [.idle]).first {
      instanceId = idle.id
    } else {
      instanceId = try await instances.create(profileName: request.profile).id
      created = true
      try await waitForIdle(instanceId, profile: profile)
    }
    let session = try await runners.startSession(instanceId: instanceId)
    return DebugRunJITResponse(
      sessionId: session.id.rawValue, instanceId: instanceId.rawValue, createdInstance: created)
  }

  /// A fresh instance is only usable once the guest agent has handshaked. The deadline is the
  /// profile's own boot + agent budget, so a slow image fails here rather than hanging the CLI.
  private func waitForIdle(_ id: InstanceID, profile: RunnerProfileConfig) async throws {
    let timeouts = profile.effectiveTimeouts
    let deadline = Date().addingTimeInterval(
      Double(timeouts.vmBoot.seconds + timeouts.agentReady.seconds + 5))
    while Date() < deadline {
      let record = try await instances.get(id: id)
      switch record.state {
      case .idle:
        return
      case .failed, .interrupted, .stopped, .deleting, .deleted:
        throw OrchestrationError.instanceNotIdle(
          id: id.rawValue, state: record.state.rawValue)
      default:
        try await Task.sleep(for: .milliseconds(250))
      }
    }
    throw OrchestrationError.instanceNotIdle(id: id.rawValue, state: "not ready in time")
  }

  private func profileNames() async throws -> [RunnerProfileID: String] {
    Dictionary(
      try await profiles.list().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }
}
