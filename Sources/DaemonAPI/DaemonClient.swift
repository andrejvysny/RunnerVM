import Foundation
import RPC

/// Typed `runnerctl`-side client. One connection, one method per catalogued call.
public actor DaemonClient {
  private let client: RPCClient
  private let socketPath: URL

  private init(client: RPCClient, socketPath: URL) {
    self.client = client
    self.socketPath = socketPath
  }

  /// Connection failures become `.unreachable` so the CLI can print the "start runnerd" hint
  /// instead of a NIO channel error.
  public static func connect(
    socketPath: URL, limits: ConnectionLimits = ConnectionLimits()
  ) async throws -> DaemonClient {
    do {
      let client = try await RPCClient.connect(
        protocol: .daemon, socketPath: socketPath, limits: limits)
      return DaemonClient(client: client, socketPath: socketPath)
    } catch {
      throw DaemonClientError.unreachable(
        path: socketPath.path(percentEncoded: false), reason: String(describing: error))
    }
  }

  public func close() async {
    await client.close()
  }

  // MARK: - Methods

  public func status() async throws -> SystemStatus { try await call(.systemStatus) }

  public func version() async throws -> VersionInfo { try await call(.systemVersion) }

  public func systemDrain(
    wait: Bool = false, timeoutMs: Int64 = 900_000
  ) async throws -> SystemModeResponse {
    try await call(.systemDrain, SystemDrainRequest(wait: wait, timeoutMs: timeoutMs))
  }

  public func systemResume() async throws -> SystemModeResponse { try await call(.systemResume) }

  public func systemOffline() async throws -> SystemModeResponse { try await call(.systemOffline) }

  public func systemShutdown(
    force: Bool = false, timeoutMs: Int64 = 900_000
  ) async throws -> SystemShutdownResponse {
    try await call(.systemShutdown, SystemShutdownRequest(force: force, timeoutMs: timeoutMs))
  }

  public func metricsSnapshot(
    format: MetricsSnapshotRequest.Format = .json
  ) async throws -> MetricsSnapshotResponse {
    try await call(.metricsSnapshot, MetricsSnapshotRequest(format: format))
  }

  public func configGet() async throws -> ConfigGetResponse { try await call(.configGet) }

  public func configValidate(yaml: String) async throws -> ConfigValidateResponse {
    try await call(.configValidate, ConfigValidateRequest(yaml: yaml))
  }

  public func configApply(yaml: String) async throws -> ConfigApplyResponse {
    try await call(.configApply, ConfigApplyRequest(yaml: yaml))
  }

  public func profileList() async throws -> ProfileListResponse { try await call(.profileList) }

  public func profileGet(name: String) async throws -> ProfileSummary {
    try await call(.profileGet, ProfileGetRequest(name: name))
  }

  public func scopeList() async throws -> ScopeListResponse { try await call(.scopeList) }

  public func scopeGet(name: String) async throws -> ScopeSummary {
    try await call(.scopeGet, ScopeGetRequest(name: name))
  }

  public func imageList() async throws -> ImageListResponse { try await call(.imageList) }

  public func imageGet(ref: String) async throws -> ImageInfoDTO {
    try await call(.imageGet, ImageGetRequest(ref: ref))
  }

  public func imageInspectRemote(
    reference: String, format: String? = nil
  ) async throws -> RemoteImageInfoDTO {
    try await call(
      .imageInspectRemote, ImageInspectRemoteRequest(reference: reference, format: format))
  }

  public func imageImport(_ request: ImageImportRequest) async throws -> ImageInfoDTO {
    try await call(.imageImport, request)
  }

  public func imagePull(reference: String, format: String? = nil) async throws -> ImagePullResponse {
    try await call(.imagePull, ImagePullRequest(reference: reference, format: format))
  }

  public func imagePush(image: String, reference: String) async throws -> ImagePushResponse {
    try await call(.imagePush, ImagePushRequest(image: image, reference: reference))
  }

  public func registryLogin(
    registry: String, username: String, password: String
  ) async throws -> RegistryLoginResponse {
    try await call(
      .registryLogin,
      RegistryLoginRequest(registry: registry, username: username, password: password))
  }

  public func registryLogout(registry: String) async throws -> RegistryLogoutResponse {
    try await call(.registryLogout, RegistryLogoutRequest(registry: registry))
  }

  public func registryStatus() async throws -> RegistryStatusResponse {
    try await call(.registryStatus)
  }

  public func imageDelete(digest: String) async throws -> ImageDeleteResponse {
    try await call(.imageDelete, ImageDeleteRequest(digest: digest))
  }

  public func imagePrune(dryRun: Bool = false) async throws -> ImagePruneResponse {
    try await call(.imagePrune, ImagePruneRequest(dryRun: dryRun))
  }

  public func imageBuild(_ request: ImageBuildRequest) async throws -> ImageBuildResponse {
    try await call(.imageBuild, request)
  }

  public func buildList() async throws -> BuildListResponse { try await call(.buildList) }

  public func buildGet(buildId: String) async throws -> BuildInfoDTO {
    try await call(.buildGet, BuildGetRequest(buildId: buildId))
  }

  public func buildLog(
    buildId: String, offset: Int64 = 0, maxBytes: Int64? = nil
  ) async throws -> BuildLogResponse {
    try await call(.buildLog, BuildLogRequest(buildId: buildId, offset: offset, maxBytes: maxBytes))
  }

  public func buildCancel(buildId: String) async throws -> BuildCancelResponse {
    try await call(.buildCancel, BuildCancelRequest(buildId: buildId))
  }

  public func instanceList() async throws -> InstanceListResponse { try await call(.instanceList) }

  public func instanceGet(id: String) async throws -> InstanceInfoDTO {
    try await call(.instanceGet, InstanceGetRequest(id: id))
  }

  public func instanceCreate(profile: String) async throws -> InstanceInfoDTO {
    try await call(.instanceCreate, InstanceCreateRequest(profile: profile))
  }

  public func instanceStop(id: String, force: Bool) async throws -> InstanceInfoDTO {
    try await call(.instanceStop, InstanceStopRequest(id: id, force: force))
  }

  public func instanceDelete(id: String) async throws -> InstanceInfoDTO {
    try await call(.instanceDelete, InstanceDeleteRequest(id: id))
  }

  public func instanceTaint(id: String, reason: String) async throws -> InstanceInfoDTO {
    try await call(.instanceTaint, InstanceTaintRequest(id: id, reason: reason))
  }

  public func instanceMetrics(id: String) async throws -> InstanceMetricsResponse {
    try await call(.instanceMetrics, InstanceMetricsRequest(id: id))
  }

  public func instanceSSHInfo(id: String) async throws -> InstanceSSHInfo {
    try await call(.instanceSSHInfo, InstanceSSHInfoRequest(id: id))
  }

  /// Streams `instance.exec`. Output arrives as it is produced; `.exited` is yielded exactly once,
  /// last. Cancelling the stream sends a `cancel` envelope, which kills the remote process group.
  public nonisolated func instanceExec(
    _ request: InstanceExecRequest
  ) throws -> AsyncThrowingStream<InstanceExecEvent, any Error> {
    let payload: JSONValue
    do {
      payload = try JSONValue(encoding: request)
    } catch {
      throw DaemonClientError.encodeFailed(
        method: DaemonMethod.instanceExec.rawValue, reason: String(describing: error))
    }
    let chunks = client.stream(method: DaemonMethod.instanceExec.rawValue, payload: payload)
    return AsyncThrowingStream<InstanceExecEvent, any Error> { continuation in
      let task = Task { await DaemonClient.pump(chunks, into: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func pump(
    _ chunks: AsyncThrowingStream<JSONValue, any Error>,
    into continuation: AsyncThrowingStream<InstanceExecEvent, any Error>.Continuation
  ) async {
    do {
      for try await value in chunks {
        // The terminal payload carries `exitCode`; every other chunk is output.
        if let code = value["exitCode"]?.intValue {
          continuation.yield(.exited(Int32(clamping: code)))
        } else {
          continuation.yield(.chunk(try value.decode(as: InstanceExecChunk.self)))
        }
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: DaemonClientError(error, method: .instanceExec))
    }
  }

  public func operationList() async throws -> OperationListResponse {
    try await call(.operationList)
  }

  public func operationGet(id: String) async throws -> OperationInfo {
    try await call(.operationGet, OperationGetRequest(id: id))
  }

  public func runnerList() async throws -> RunnerListResponse { try await call(.runnerList) }

  public func scaleSetList() async throws -> ScaleSetListResponse { try await call(.scaleSetList) }

  public func runnerGet(sessionId: String) async throws -> RunnerSessionDTO {
    try await call(.runnerGet, RunnerGetRequest(sessionId: sessionId))
  }

  public func authStatus() async throws -> AuthStatus { try await call(.authStatus) }

  public func authLogin(token: String) async throws -> AuthLoginResponse {
    try await call(.authLogin, AuthLoginRequest(token: token))
  }

  public func authLogout() async throws -> AuthLogoutResponse { try await call(.authLogout) }

  public func githubTest() async throws -> GitHubTestResponse { try await call(.githubTest) }

  public func debugDemandSet(
    profile: String, assignedJobs: Int
  ) async throws -> DebugDemandSetResponse {
    try await call(
      .debugDemandSet, DebugDemandSetRequest(profile: profile, assignedJobs: assignedJobs))
  }

  public func debugRunJIT(profile: String) async throws -> DebugRunJITResponse {
    try await call(.debugRunJIT, DebugRunJITRequest(profile: profile))
  }

  public func debugScaleSetReconnect(profile: String) async throws -> DebugScaleSetReconnectResponse {
    try await call(.debugScaleSetReconnect, DebugScaleSetReconnectRequest(profile: profile))
  }

  /// Escape hatch for catalogued methods with no typed wrapper yet; answers NOT_IMPLEMENTED.
  public func callRaw(_ method: DaemonMethod, payload: JSONValue? = nil) async throws -> JSONValue {
    do {
      return try await client.call(method: method.rawValue, payload: payload)
    } catch {
      throw DaemonClientError(error, method: method)
    }
  }

  // MARK: - Transport

  private func call<Response: Decodable & Sendable>(_ method: DaemonMethod) async throws -> Response {
    try decode(await callRaw(method), method: method)
  }

  private func call<Request: Encodable & Sendable, Response: Decodable & Sendable>(
    _ method: DaemonMethod, _ request: Request
  ) async throws -> Response {
    let payload: JSONValue
    do {
      payload = try JSONValue(encoding: request)
    } catch {
      throw DaemonClientError.encodeFailed(
        method: method.rawValue, reason: String(describing: error))
    }
    return try decode(await callRaw(method, payload: payload), method: method)
  }

  private func decode<Response: Decodable>(
    _ value: JSONValue, method: DaemonMethod
  ) throws -> Response {
    do {
      return try value.decode(as: Response.self)
    } catch {
      throw DaemonClientError.decodeFailed(
        method: method.rawValue, reason: String(describing: error))
    }
  }
}

/// Failure surface `runnerctl` branches on for its exit code.
public enum DaemonClientError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The daemon answered with an `error` member.
  case remote(method: String, code: String, message: String, retryable: Bool)
  /// The socket could not be connected: no daemon, or the wrong path.
  case unreachable(path: String, reason: String)
  /// The connection dropped mid-call.
  case disconnected(method: String)
  case encodeFailed(method: String, reason: String)
  case decodeFailed(method: String, reason: String)

  init(_ error: any Error, method: DaemonMethod) {
    switch error {
    case let clientError as DaemonClientError:
      self = clientError
    case let callError as RPCCallError:
      if let payload = callError.payload {
        self = .remote(
          method: method.rawValue, code: payload.code, message: payload.message,
          retryable: payload.retryable)
      } else if case .disconnected = callError {
        self = .disconnected(method: method.rawValue)
      } else {
        self = .remote(
          method: method.rawValue, code: callError.code?.rawValue ?? "INTERNAL",
          message: String(describing: callError), retryable: false)
      }
    default:
      self = .remote(
        method: method.rawValue, code: "INTERNAL", message: String(describing: error),
        retryable: false)
    }
  }

  public var code: String {
    switch self {
    case let .remote(_, code, _, _): code
    case .unreachable: "DAEMON_UNREACHABLE"
    case .disconnected: "DAEMON_DISCONNECTED"
    case .encodeFailed: "REQUEST_ENCODE_FAILED"
    case .decodeFailed: "RESPONSE_DECODE_FAILED"
    }
  }

  public var message: String {
    switch self {
    case let .remote(method, _, message, _): "\(method): \(message)"
    case let .unreachable(path, reason): "cannot connect to \(path): \(reason)"
    case let .disconnected(method): "\(method): daemon closed the connection"
    case let .encodeFailed(method, reason): "\(method): \(reason)"
    case let .decodeFailed(method, reason): "\(method): \(reason)"
    }
  }

  /// True when nothing is listening on the socket at all.
  public var isUnreachable: Bool {
    switch self {
    case .unreachable, .disconnected: true
    default: false
    }
  }

  public var description: String { "\(code): \(message)" }
}
