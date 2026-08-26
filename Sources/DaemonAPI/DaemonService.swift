import Foundation

/// What `runnerd` must provide for the M1 slice of the catalogue. `DaemonServer` routes decoded
/// envelopes here; `DaemonClient` mirrors it over the socket.
public protocol DaemonService: Sendable {
  func status() async throws -> SystemStatus
  func version() async throws -> VersionInfo

  /// Spec §109: stop advertising capacity and admit no new work; in-flight jobs finish.
  func systemDrain(_ request: SystemDrainRequest) async throws -> SystemModeResponse
  /// Back to `normal`, from either `draining` or `offline`.
  func systemResume() async throws -> SystemModeResponse
  /// Drains first when the host is still `normal`, then parks it in `offline`.
  func systemOffline() async throws -> SystemModeResponse
  /// Spec §108. Returns before the daemon actually stops, so the caller sees a reply.
  func systemShutdown(_ request: SystemShutdownRequest) async throws -> SystemShutdownResponse

  /// Spec §43. `format: prometheus` also returns the rendered exposition text.
  func metricsSnapshot(_ request: MetricsSnapshotRequest) async throws -> MetricsSnapshotResponse

  func configGet() async throws -> ConfigGetResponse
  func configValidate(_ request: ConfigValidateRequest) async throws -> ConfigValidateResponse
  func configApply(_ request: ConfigApplyRequest) async throws -> ConfigApplyResponse

  func profileList() async throws -> ProfileListResponse
  func profileGet(_ request: ProfileGetRequest) async throws -> ProfileSummary
  func scopeList() async throws -> ScopeListResponse
  func scopeGet(_ request: ScopeGetRequest) async throws -> ScopeSummary

  func imageList() async throws -> ImageListResponse
  func imageGet(_ request: ImageGetRequest) async throws -> ImageInfoDTO
  func imageImport(_ request: ImageImportRequest) async throws -> ImageInfoDTO
  func imageDelete(_ request: ImageDeleteRequest) async throws -> ImageDeleteResponse
  func imagePrune(_ request: ImagePruneRequest) async throws -> ImagePruneResponse

  func instanceList() async throws -> InstanceListResponse
  func instanceGet(_ request: InstanceGetRequest) async throws -> InstanceInfoDTO
  func instanceCreate(_ request: InstanceCreateRequest) async throws -> InstanceInfoDTO
  func instanceStop(_ request: InstanceStopRequest) async throws -> InstanceInfoDTO
  func instanceDelete(_ request: InstanceDeleteRequest) async throws -> InstanceInfoDTO
  /// Spec §126: marks the VM untrustworthy. Idle ⇒ recycled now; busy ⇒ retired after the job.
  func instanceTaint(_ request: InstanceTaintRequest) async throws -> InstanceInfoDTO
  func instanceMetrics(_ request: InstanceMetricsRequest) async throws -> InstanceMetricsResponse
  func instanceSSHInfo(_ request: InstanceSSHInfoRequest) async throws -> InstanceSSHInfo

  /// Streams `instance.exec`. `emit` is called once per output chunk, in order; the returned
  /// exit code becomes the terminal payload-bearing chunk.
  func instanceExec(
    _ request: InstanceExecRequest,
    emit: @escaping @Sendable (InstanceExecChunk) async throws -> Void
  ) async throws -> InstanceExecResult

  func operationList() async throws -> OperationListResponse
  func operationGet(_ request: OperationGetRequest) async throws -> OperationInfo

  /// Per-profile demand: scale set, message session, cursor and advertised capacity (spec §14).
  func scaleSetList() async throws -> ScaleSetListResponse

  func runnerList() async throws -> RunnerListResponse
  func runnerGet(_ request: RunnerGetRequest) async throws -> RunnerSessionDTO

  /// Cached; never talks to GitHub, so `runnerctl status` stays an offline call.
  func authStatus() async throws -> AuthStatus
  func authLogin(_ request: AuthLoginRequest) async throws -> AuthLoginResponse
  func authLogout() async throws -> AuthLogoutResponse
  /// Live probe of the credential and every configured scope (spec §148).
  func githubTest() async throws -> GitHubTestResponse
  func debugRunJIT(_ request: DebugRunJITRequest) async throws -> DebugRunJITResponse
  /// Overrides local demand. Rejected unless the daemon runs the manual demand provider.
  func debugDemandSet(_ request: DebugDemandSetRequest) async throws -> DebugDemandSetResponse
}

/// Errors a `DaemonService` implementation raises that map onto daemon-specific wire codes.
public enum DaemonServiceError: Error, Sendable, Hashable, CustomStringConvertible {
  case notFound(entity: String, name: String)
  case notImplemented(DaemonMethod)
  case unavailable(reason: String)

  public var code: String {
    switch self {
    case .notFound: DaemonErrorCode.notFound
    case .notImplemented: DaemonErrorCode.notImplemented
    case .unavailable: "UNAVAILABLE"
    }
  }

  public var message: String {
    switch self {
    case let .notFound(entity, name): "\(entity) '\(name)' not found"
    case let .notImplemented(method): "method '\(method.rawValue)' is not implemented yet"
    case let .unavailable(reason): reason
    }
  }

  public var description: String { "\(code): \(message)" }
}
