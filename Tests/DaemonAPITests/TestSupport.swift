import Foundation
import GuestControl
import RunnerCore

@testable import DaemonAPI

/// Short path under /tmp: `sockaddr_un.sun_path` holds only 104 bytes.
func makeSocketPath() throws -> URL {
  let directory = URL(
    fileURLWithPath: "/tmp/rvm-api-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("runnerd.sock")
}

func removeSocketDirectory(_ path: URL) {
  try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
}

func sampleStatus(profiles: [String] = ["ubuntu-24"]) -> SystemStatus {
  SystemStatus(
    daemon: DaemonHealth(
      state: .healthy, version: "1.2.3", pid: 4242, hostId: "host-1", mode: "normal",
      startedAt: "2026-01-01T00:00:00.000Z", uptimeSeconds: 61),
    host: HostSummary(
      osVersion: "15.4.0", architecture: "arm64", logicalCPUCount: 12,
      physicalMemoryBytes: 68_719_476_736, freeDiskBytes: 442_381_500_416,
      virtualizationSupported: true, nestedVirtualizationSupported: false, macOSGuestLimit: 2,
      probeSucceeded: true),
    capacity: CapacitySummary(
      runningVMs: 2, maxVMs: 4, reservedCPUCount: 2, reservedMemoryBytes: 6_442_450_944,
      reservedDiskBytes: 53_687_091_200, placeholder: true),
    github: GitHubSummary(
      authState: "healthy", scopeCount: 2, scaleSetsHealthy: 3, placeholder: false),
    images: ImageSummary(cached: 5, diskUsageBytes: 196_499_243_008),
    profiles: profiles.map {
      ProfileRuntimeSummary(name: $0, enabled: true, busy: 1, idle: 0, demand: 3, starting: 1)
    },
    reconciliation: ReconciliationSummary(
      lastRunAt: "2026-01-01T00:01:00.000Z", secondsSinceLastRun: 4, runCount: 7),
    diskPressure: DiskPressureSummary(
      freeBytes: 442_381_500_416, floorBytes: 53_687_091_200, state: "ok"))
}

/// Minimal `DaemonService` that answers from canned values and records what it was asked.
actor FakeDaemonService: DaemonService {
  var status_ = sampleStatus()
  var validateIssues: [ConfigurationIssue] = []
  var lastValidatedYAML: String?
  var lastAppliedYAML: String?
  var profiles: [ProfileSummary] = []
  var scopes: [ScopeSummary] = []
  var images: [ImageInfoDTO] = []
  var instances: [InstanceInfoDTO] = []
  var lastImportedPath: String?
  var lastImportRequest: ImageImportRequest?
  var metrics = FakeGuestAgent.Script.defaultMetrics
  var sshInfo = InstanceSSHInfo(
    ipAddresses: ["192.168.64.7"], user: InstanceSSHInfo.defaultUser, sshEnabled: true)
  var execScript: [InstanceExecEvent] = [
    .chunk(InstanceExecChunk(stream: "stdout", data: Data("hello\n".utf8))),
    .chunk(InstanceExecChunk(stream: "stderr", data: Data("warn\n".utf8))),
    .exited(3),
  ]
  var lastExecRequest: InstanceExecRequest?

  func setSSHInfo(_ info: InstanceSSHInfo) { sshInfo = info }
  func setExecScript(_ script: [InstanceExecEvent]) { execScript = script }
  func execRequest() -> InstanceExecRequest? { lastExecRequest }

  func setValidateIssues(_ issues: [ConfigurationIssue]) { validateIssues = issues }
  func setProfiles(_ summaries: [ProfileSummary]) { profiles = summaries }
  func setScopes(_ summaries: [ScopeSummary]) { scopes = summaries }
  func validatedYAML() -> String? { lastValidatedYAML }
  func appliedYAML() -> String? { lastAppliedYAML }

  func status() async throws -> SystemStatus { status_ }

  func version() async throws -> VersionInfo {
    VersionInfo(version: "1.2.3", protocolName: "daemon", protocolVersion: 1, schemaVersion: 1)
  }

  var mode = "normal"
  var activeSessions = 2
  var lastDrain: SystemDrainRequest?
  var lastShutdown: SystemShutdownRequest?

  func drainRequest() -> SystemDrainRequest? { lastDrain }
  func shutdownRequest() -> SystemShutdownRequest? { lastShutdown }
  func currentMode() -> String { mode }
  func setActiveSessions(_ count: Int) { activeSessions = count }

  func systemDrain(_ request: SystemDrainRequest) async throws -> SystemModeResponse {
    lastDrain = request
    mode = "draining"
    if request.wait { activeSessions = 0 }
    return SystemModeResponse(
      mode: mode, activeSessions: activeSessions, drained: activeSessions == 0)
  }

  func systemResume() async throws -> SystemModeResponse {
    mode = "normal"
    return SystemModeResponse(mode: mode, activeSessions: activeSessions, drained: true)
  }

  func systemOffline() async throws -> SystemModeResponse {
    mode = "offline"
    return SystemModeResponse(mode: mode, activeSessions: activeSessions, drained: true)
  }

  func systemShutdown(_ request: SystemShutdownRequest) async throws -> SystemShutdownResponse {
    lastShutdown = request
    guard request.force || activeSessions == 0 else {
      throw DaemonServiceError.unavailable(reason: "\(activeSessions) runner session(s) active")
    }
    mode = "draining"
    return SystemShutdownResponse(accepted: true, mode: mode, activeSessions: activeSessions)
  }

  var snapshot = MetricsSnapshotResponse(
    collectedAt: "2026-01-01T00:03:00Z",
    families: [
      MetricFamilyDTO(
        name: "runnervm_sessions_total", type: "counter", help: "Sessions.",
        samples: [
          MetricSampleDTO(
            labels: [
              MetricLabelDTO(name: "profile", value: "ubuntu-24"),
              MetricLabelDTO(name: "result", value: "completed"),
            ], value: 4),
        ]),
    ])

  func metricsSnapshot(_ request: MetricsSnapshotRequest) async throws -> MetricsSnapshotResponse {
    var response = snapshot
    if request.format == .prometheus {
      response.prometheus = "# TYPE runnervm_sessions_total counter\n"
    }
    return response
  }

  func configGet() async throws -> ConfigGetResponse {
    ConfigGetResponse(yaml: lastAppliedYAML, appliedAt: "2026-01-01T00:00:00.000Z")
  }

  func configValidate(_ request: ConfigValidateRequest) async throws -> ConfigValidateResponse {
    lastValidatedYAML = request.yaml
    return ConfigValidateResponse(issues: validateIssues)
  }

  func configApply(_ request: ConfigApplyRequest) async throws -> ConfigApplyResponse {
    lastAppliedYAML = request.yaml
    return ConfigApplyResponse(
      diff: ConfigDiff(addedScopes: ["engineering"], addedProfiles: ["ubuntu-24"]),
      operationId: "op-1", issues: validateIssues.warnings,
      appliedAt: "2026-01-01T00:00:00.000Z")
  }

  func profileList() async throws -> ProfileListResponse {
    ProfileListResponse(profiles: profiles)
  }

  func profileGet(_ request: ProfileGetRequest) async throws -> ProfileSummary {
    guard let match = profiles.first(where: { $0.name == request.name }) else {
      throw DaemonServiceError.notFound(entity: "profile", name: request.name)
    }
    return match
  }

  func imageList() async throws -> ImageListResponse { ImageListResponse(images: images) }

  func imageGet(_ request: ImageGetRequest) async throws -> ImageInfoDTO {
    guard let match = images.first(where: { $0.digest == request.ref || $0.name == request.ref })
    else { throw DaemonServiceError.notFound(entity: "image", name: request.ref) }
    return match
  }

  func imageImport(_ request: ImageImportRequest) async throws -> ImageInfoDTO {
    lastImportedPath = request.path
    lastImportRequest = request
    let image = FakeDaemonService.sampleImage(name: request.name, os: request.os)
    images.append(image)
    return image
  }

  var lastPullRequest: ImagePullRequest?
  var lastPushRequest: ImagePushRequest?

  func imagePull(_ request: ImagePullRequest) async throws -> ImagePullResponse {
    lastPullRequest = request
    return ImagePullResponse(
      reference: request.reference + "@sha256:" + String(repeating: "c", count: 64),
      manifestDigest: "sha256:" + String(repeating: "c", count: 64),
      operationId: "op-pull", alreadyPresent: false, digest: nil)
  }

  func imagePush(_ request: ImagePushRequest) async throws -> ImagePushResponse {
    lastPushRequest = request
    return ImagePushResponse(
      reference: request.reference, digest: "sha256:" + String(repeating: "a", count: 64),
      operationId: "op-push")
  }

  var registryLogins: [RegistryLoginRequest] = []
  var registryLogouts: [String] = []

  func registryLogin(_ request: RegistryLoginRequest) async throws -> RegistryLoginResponse {
    registryLogins.append(request)
    return RegistryLoginResponse(
      registry: request.registry, username: request.username,
      location: "keychain \(request.registry)")
  }

  func registryLogout(_ request: RegistryLogoutRequest) async throws -> RegistryLogoutResponse {
    registryLogouts.append(request.registry)
    return RegistryLogoutResponse(registry: request.registry, removed: true)
  }

  func registryStatus() async throws -> RegistryStatusResponse {
    RegistryStatusResponse(
      registries: [
        RegistryCredentialDTO(
          registry: "ghcr.io", provider: "keychain", username: "octocat", profiles: ["linux"]),
      ])
  }

  func imageDelete(_ request: ImageDeleteRequest) async throws -> ImageDeleteResponse {
    images.removeAll { $0.digest == request.digest }
    return ImageDeleteResponse(digest: request.digest)
  }

  var lastPruneRequest: ImagePruneRequest?

  func imagePrune(_ request: ImagePruneRequest) async throws -> ImagePruneResponse {
    lastPruneRequest = request
    return ImagePruneResponse(
      candidates: ["sha256:" + String(repeating: "a", count: 64)],
      deleted: request.dryRun ? [] : ["sha256:" + String(repeating: "a", count: 64)],
      keptPinned: [], reclaimedBytes: request.dryRun ? 0 : 2_000_000_000, staleStagingRemoved: 1)
  }

  // MARK: - image.build / build.*

  var builds: [BuildInfoDTO] = []
  var lastBuildRequest: ImageBuildRequest?
  var lastCancelledBuildId: String?

  func imageBuild(_ request: ImageBuildRequest) async throws -> ImageBuildResponse {
    lastBuildRequest = request
    return ImageBuildResponse(
      buildId: "build-1", operationId: "op-build-1", name: request.name,
      from: "ghcr.io/acme/ubuntu-24:stable", totalSteps: 3)
  }

  func buildList() async throws -> BuildListResponse { BuildListResponse(builds: builds) }

  func buildGet(_ request: BuildGetRequest) async throws -> BuildInfoDTO {
    guard let match = builds.first(where: { $0.buildId == request.buildId }) else {
      throw DaemonServiceError.notFound(entity: "build", name: request.buildId)
    }
    return match
  }

  func buildLog(_ request: BuildLogRequest) async throws -> BuildLogResponse {
    BuildLogResponse(data: "", nextOffset: request.offset, done: true)
  }

  func buildCancel(_ request: BuildCancelRequest) async throws -> BuildCancelResponse {
    lastCancelledBuildId = request.buildId
    return BuildCancelResponse(buildId: request.buildId, state: "cancelled")
  }

  var scaleSets: [ScaleSetSummary] = []
  var lastDemand: DebugDemandSetRequest?

  func setScaleSets(_ rows: [ScaleSetSummary]) { scaleSets = rows }
  func demandRequest() -> DebugDemandSetRequest? { lastDemand }

  func scaleSetList() async throws -> ScaleSetListResponse {
    ScaleSetListResponse(scaleSets: scaleSets)
  }

  func debugDemandSet(_ request: DebugDemandSetRequest) async throws -> DebugDemandSetResponse {
    lastDemand = request
    return DebugDemandSetResponse(profile: request.profile, assignedJobs: request.assignedJobs)
  }

  var lastReconnect: DebugScaleSetReconnectRequest?

  func reconnectRequest() -> DebugScaleSetReconnectRequest? { lastReconnect }

  func debugScaleSetReconnect(
    _ request: DebugScaleSetReconnectRequest
  ) async throws -> DebugScaleSetReconnectResponse {
    lastReconnect = request
    return DebugScaleSetReconnectResponse(profile: request.profile)
  }

  func instanceList() async throws -> InstanceListResponse {
    InstanceListResponse(instances: instances)
  }

  func instanceGet(_ request: InstanceGetRequest) async throws -> InstanceInfoDTO {
    guard let match = instances.first(where: { $0.id == request.id }) else {
      throw DaemonServiceError.notFound(entity: "instance", name: request.id)
    }
    return match
  }

  func instanceCreate(_ request: InstanceCreateRequest) async throws -> InstanceInfoDTO {
    let instance = FakeDaemonService.sampleInstance(profile: request.profile)
    instances.append(instance)
    return instance
  }

  func instanceStop(_ request: InstanceStopRequest) async throws -> InstanceInfoDTO {
    try await mutateInstance(request.id) { $0.state = "stopped" }
  }

  func instanceDelete(_ request: InstanceDeleteRequest) async throws -> InstanceInfoDTO {
    try await mutateInstance(request.id) { $0.state = "deleted" }
  }

  func instanceTaint(_ request: InstanceTaintRequest) async throws -> InstanceInfoDTO {
    try await mutateInstance(request.id) {
      $0.tainted = true
      $0.taintReason = request.reason
      $0.state = "deleted"
    }
  }

  func instanceMetrics(_ request: InstanceMetricsRequest) async throws -> InstanceMetricsResponse {
    InstanceMetricsResponse(
      instanceId: request.id, collectedAt: "2026-01-01T00:02:00.000Z", guest: metrics,
      worker: WorkerProcessMetrics(pid: 4_242, rssBytes: 1_048_576, cpuSeconds: 1.5))
  }

  func instanceSSHInfo(_ request: InstanceSSHInfoRequest) async throws -> InstanceSSHInfo {
    sshInfo
  }

  func instanceExec(
    _ request: InstanceExecRequest,
    emit: @escaping @Sendable (InstanceExecChunk) async throws -> Void
  ) async throws -> InstanceExecResult {
    lastExecRequest = request
    guard request.id != "missing" else {
      throw DaemonServiceError.notFound(entity: "instance", name: request.id)
    }
    var exitCode: Int32 = 0
    for event in execScript {
      switch event {
      case .chunk(let chunk): try await emit(chunk)
      case .exited(let code): exitCode = code
      }
    }
    return InstanceExecResult(exitCode: exitCode)
  }

  private func mutateInstance(
    _ id: String, _ body: (inout InstanceInfoDTO) -> Void
  ) async throws -> InstanceInfoDTO {
    guard let index = instances.firstIndex(where: { $0.id == id }) else {
      throw DaemonServiceError.notFound(entity: "instance", name: id)
    }
    body(&instances[index])
    return instances[index]
  }

  static func sampleImage(name: String?, os: String) -> ImageInfoDTO {
    ImageInfoDTO(
      digest: "sha256:" + String(repeating: "a", count: 64), name: name, os: os,
      architecture: "arm64", state: "ready", virtualSizeBytes: 21_474_836_480,
      allocatedSizeBytes: 2_000_000_000, localPath: "/tmp/images/sha256-aaa", pinCount: 0,
      createdAt: "2026-01-01T00:00:00.000Z", runnerVersion: "2.320.0",
      runnerVersionHealth: .stale)
  }

  static func sampleInstance(profile: String) -> InstanceInfoDTO {
    InstanceInfoDTO(
      id: "11111111-2222-3333-4444-555555555555", name: "rvm-\(profile)-11111111",
      profile: profile, imageDigest: "sha256:" + String(repeating: "a", count: 64),
      state: "waitingForAgent", vmState: "running", workerPid: 4_242, workerGeneration: 1,
      cpuCount: 2, memoryBytes: 2_147_483_648, diskBytes: 21_474_836_480,
      diskReservationBytes: 21_474_836_480, createdAt: "2026-01-01T00:00:00.000Z",
      startedAt: "2026-01-01T00:00:10.000Z")
  }

  func scopeList() async throws -> ScopeListResponse { ScopeListResponse(scopes: scopes) }

  func scopeGet(_ request: ScopeGetRequest) async throws -> ScopeSummary {
    guard let match = scopes.first(where: { $0.name == request.name }) else {
      throw DaemonServiceError.notFound(entity: "scope", name: request.name)
    }
    return match
  }

  func operationList() async throws -> OperationListResponse {
    OperationListResponse(operations: [])
  }

  func operationGet(_ request: OperationGetRequest) async throws -> OperationInfo {
    throw DaemonServiceError.notFound(entity: "operation", name: request.id)
  }

  // MARK: - M5 surface

  var sessions: [RunnerSessionDTO] = []
  var auth = AuthStatus(
    state: "healthy", provider: "pat", source: "keychain",
    location: "keychain com.runnervm.github/default", login: "octocat")
  var lastLoginToken: String?

  func runnerList() async throws -> RunnerListResponse { RunnerListResponse(sessions: sessions) }

  func runnerGet(_ request: RunnerGetRequest) async throws -> RunnerSessionDTO {
    guard let match = sessions.first(where: { $0.id == request.sessionId }) else {
      throw DaemonServiceError.notFound(entity: "runner session", name: request.sessionId)
    }
    return match
  }

  func authStatus() async throws -> AuthStatus { auth }

  func authLogin(_ request: AuthLoginRequest) async throws -> AuthLoginResponse {
    lastLoginToken = request.token
    return AuthLoginResponse(location: auth.location, status: auth)
  }

  func authLogout() async throws -> AuthLogoutResponse {
    lastLoginToken = nil
    return AuthLogoutResponse(location: auth.location, removed: true)
  }

  func githubTest() async throws -> GitHubTestResponse {
    GitHubTestResponse(auth: auth, scopes: [])
  }

  func debugRunJIT(_ request: DebugRunJITRequest) async throws -> DebugRunJITResponse {
    DebugRunJITResponse(
      sessionId: "session-1", instanceId: "instance-1", createdInstance: true)
  }
}
