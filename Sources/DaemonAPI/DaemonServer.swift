import Foundation
import RPC
import RunnerCore

/// Typed front end for `RPCServer` on the `daemon` protocol: registers every catalogued method,
/// decodes payloads into DTOs and turns thrown errors into wire error payloads.
public actor DaemonServer {
  private let service: any DaemonService
  private let server: RPCServer
  private var started = false

  public init(
    service: any DaemonService,
    socketPath: URL,
    allowedUIDs: Set<uid_t>? = nil,
    limits: ConnectionLimits = ConnectionLimits()
  ) {
    self.service = service
    self.server = RPCServer(
      protocol: .daemon, socketPath: socketPath, allowedUIDs: allowedUIDs, limits: limits)
  }

  /// Registers the whole catalogue, then binds. `RPCServer` snapshots handlers per connection,
  /// so every method must be registered before this returns.
  public func start() async throws {
    guard !started else { throw RPCServerError.alreadyStarted }
    await registerImplemented()
    await registerStubs()
    try await server.start()
    started = true
  }

  public func stop() async {
    guard started else { return }
    await server.stop()
    started = false
  }

  // MARK: - Registration

  private func registerImplemented() async {
    let service = self.service
    await unary(.systemStatus) { try await service.status() }
    await unary(.systemVersion) { try await service.version() }
    await unary(.systemResume) { try await service.systemResume() }
    await unary(.systemOffline) { try await service.systemOffline() }
    await unary(.configGet) { try await service.configGet() }
    await unary(.profileList) { try await service.profileList() }
    await unary(.scopeList) { try await service.scopeList() }
    await unary(.operationList) { try await service.operationList() }
    await unary(.imageList) { try await service.imageList() }
    await unary(.instanceList) { try await service.instanceList() }
    await unary(.runnerList) { try await service.runnerList() }
    await unary(.scaleSetList) { try await service.scaleSetList() }
    await unary(.registryStatus) { try await service.registryStatus() }
    await unary(.authStatus) { try await service.authStatus() }
    await unary(.authLogout) { try await service.authLogout() }
    await unary(.githubTest) { try await service.githubTest() }

    await request(.systemDrain) { try await service.systemDrain($0) }
    await request(.systemShutdown) { try await service.systemShutdown($0) }
    await request(.metricsSnapshot) { try await service.metricsSnapshot($0) }
    await request(.configValidate) { try await service.configValidate($0) }
    await request(.configApply) { try await service.configApply($0) }
    await request(.profileGet) { try await service.profileGet($0) }
    await request(.scopeGet) { try await service.scopeGet($0) }
    await request(.operationGet) { try await service.operationGet($0) }
    await request(.imageGet) { try await service.imageGet($0) }
    await request(.imageImport) { try await service.imageImport($0) }
    await request(.imagePull) { try await service.imagePull($0) }
    await request(.imagePush) { try await service.imagePush($0) }
    await request(.registryLogin) { try await service.registryLogin($0) }
    await request(.registryLogout) { try await service.registryLogout($0) }
    await request(.imageDelete) { try await service.imageDelete($0) }
    await request(.imagePrune) { try await service.imagePrune($0) }
    await request(.instanceGet) { try await service.instanceGet($0) }
    await request(.instanceCreate) { try await service.instanceCreate($0) }
    await request(.instanceStop) { try await service.instanceStop($0) }
    await request(.instanceDelete) { try await service.instanceDelete($0) }
    await request(.instanceTaint) { try await service.instanceTaint($0) }
    await request(.instanceMetrics) { try await service.instanceMetrics($0) }
    await request(.instanceSSHInfo) { try await service.instanceSSHInfo($0) }
    await request(.runnerGet) { try await service.runnerGet($0) }
    await request(.authLogin) { try await service.authLogin($0) }
    await request(.debugRunJIT) { try await service.debugRunJIT($0) }
    await request(.debugDemandSet) { try await service.debugDemandSet($0) }
    await registerExec()
  }

  /// `instance.exec` is the only streaming method with a handler today. Output chunks go out as
  /// they arrive; the exit code is the last payload-bearing chunk, before the transport's empty
  /// `end: true` frame.
  private func registerExec() async {
    let service = self.service
    await server.registerStream(
      method: DaemonMethod.instanceExec.rawValue, class: DaemonMethod.instanceExec.methodClass
    ) { envelope, _, sink in
      let request: InstanceExecRequest = try DaemonServer.decode(envelope, method: .instanceExec)
      do {
        let result = try await service.instanceExec(request) { chunk in
          try await sink.send(try JSONValue(encoding: chunk))
        }
        try await sink.send(try JSONValue(encoding: result))
      } catch {
        throw DaemonServer.wireError(error)
      }
    }
  }

  private func registerStubs() async {
    for method in DaemonMethod.allCases where !method.isImplemented {
      await server.register(method: method.rawValue, class: method.methodClass) { _, _ in
        throw DaemonServer.failure(DaemonServiceError.notImplemented(method))
      }
    }
  }

  private func unary<Response: Encodable & Sendable>(
    _ method: DaemonMethod,
    _ body: @escaping @Sendable () async throws -> Response
  ) async {
    await server.register(method: method.rawValue, class: method.methodClass) { _, _ in
      try await DaemonServer.encode { try await body() }
    }
  }

  private func request<Request: Decodable & Sendable, Response: Encodable & Sendable>(
    _ method: DaemonMethod,
    _ body: @escaping @Sendable (Request) async throws -> Response
  ) async {
    await server.register(method: method.rawValue, class: method.methodClass) { envelope, _ in
      let decoded: Request = try DaemonServer.decode(envelope, method: method)
      return try await DaemonServer.encode { try await body(decoded) }
    }
  }

  // MARK: - Payload bridging

  private static func decode<Request: Decodable>(
    _ envelope: Envelope, method: DaemonMethod
  ) throws -> Request {
    do {
      return try (envelope.payload ?? .emptyObject).decode(as: Request.self)
    } catch {
      throw RPCCallError.remote(
        RPCErrorPayload(
          code: .invalidParams,
          message: "\(method.rawValue): \(String(describing: error))"))
    }
  }

  private static func encode<Response: Encodable>(
    _ body: () async throws -> Response
  ) async throws -> JSONValue {
    do {
      return try JSONValue(encoding: try await body())
    } catch {
      throw wireError(error)
    }
  }

  /// Turns a service-level failure into the payload the peer sees. Anything unrecognized is left
  /// alone so `ServerConnection` can report it as `INTERNAL`.
  static func wireError(_ error: any Error) -> any Error {
    switch error {
    case let error as RPCCallError:
      return error
    case let error as DaemonServiceError:
      return failure(error)
    case let error as any RunnerError:
      return RPCCallError.remote(
        RPCErrorPayload(code: error.code, message: error.message, retryable: error.retryable))
    default:
      return error
    }
  }

  private static func failure(_ error: DaemonServiceError) -> RPCCallError {
    .remote(RPCErrorPayload(code: error.code, message: error.message))
  }
}
