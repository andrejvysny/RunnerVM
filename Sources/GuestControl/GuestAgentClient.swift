import Foundation
import RPC
import RunnerCore

/// Typed client for one guest agent, reached through vmworker's UDS bridge.
///
/// Every UDS connection to the bridge is a fresh vsock dial into the guest; the worker closes it
/// immediately when the guest has no agent listening yet. A connect or first-call failure is
/// therefore "not ready", not "broken" — ``waitUntilReady(timeout:policy:)`` is the supported way
/// to get from a booted VM to a usable agent.
public actor GuestAgentClient {
  /// Backoff schedule for ``waitUntilReady(timeout:policy:)``. Injected in tests so readiness is
  /// driven by the fake agent's health script rather than by wall-clock sleeps.
  public struct ReadinessPolicy: Sendable, Hashable {
    public var initialBackoff: Duration
    public var maxBackoff: Duration
    public var multiplier: Int

    public init(
      initialBackoff: Duration = .milliseconds(200), maxBackoff: Duration = .seconds(2),
      multiplier: Int = 2
    ) {
      self.initialBackoff = initialBackoff
      self.maxBackoff = maxBackoff
      self.multiplier = multiplier
    }
  }

  public nonisolated let socketPath: URL
  private let limits: ConnectionLimits
  private let callDeadline: Duration
  private var client: RPCClient?
  private var closed = false

  public init(
    socketPath: URL, limits: ConnectionLimits = ConnectionLimits(),
    callDeadline: Duration = .seconds(30)
  ) {
    self.socketPath = socketPath
    self.limits = limits
    self.callDeadline = callDeadline
  }

  /// Terminal: a closed client never reconnects. Create a new one for a new guest incarnation.
  public func close() async {
    closed = true
    await client?.close()
    client = nil
  }

  // MARK: - Methods

  public func hello() async throws -> HelloResponse {
    let hello = try decode(HelloResponse.self, from: try await call(.hello), method: .hello)
    guard hello.protocolVersion == GuestProtocolVersion.current else {
      throw GuestAgentError.protocolVersionUnsupported(
        guest: hello.protocolVersion, host: GuestProtocolVersion.current)
    }
    return hello
  }

  public func health() async throws -> HealthResponse {
    try decode(HealthResponse.self, from: try await call(.health), method: .health)
  }

  public func getInfo() async throws -> GuestInfo {
    try decode(GuestInfo.self, from: try await call(.getInfo), method: .getInfo)
  }

  public func getMetrics() async throws -> GuestMetrics {
    try decode(GuestMetrics.self, from: try await call(.getMetrics), method: .getMetrics)
  }

  public func resizeDisk() async throws -> ResizeDiskResponse {
    try decode(ResizeDiskResponse.self, from: try await call(.resizeDisk), method: .resizeDisk)
  }

  /// `singleShot`: never retried on the wire, because a second spawn for the same `sessionId` is
  /// answered `ALREADY_STARTED` and a blind retry would hide a real double-start.
  public func startRunner(_ request: StartRunnerRequest) async throws -> StartRunnerResponse {
    let payload = try GuestCoding.payload(request)
    return try decode(
      StartRunnerResponse.self,
      from: try await call(.startRunner, payload: payload, allowReconnect: false),
      method: .startRunner)
  }

  public func runnerStatus(sessionId: String) async throws -> RunnerStatus {
    let payload = try GuestCoding.payload(RunnerStatusRequest(sessionId: sessionId))
    return try decode(
      RunnerStatus.self, from: try await call(.runnerStatus, payload: payload),
      method: .runnerStatus)
  }

  public func stopRunner(_ request: StopRunnerRequest) async throws -> StopRunnerResponse {
    let payload = try GuestCoding.payload(request)
    return try decode(
      StopRunnerResponse.self, from: try await call(.stopRunner, payload: payload),
      method: .stopRunner)
  }

  public func cleanup(epoch: Int64) async throws -> CleanupResponse {
    let payload = try GuestCoding.payload(CleanupRequest(epoch: epoch))
    return try decode(
      CleanupResponse.self, from: try await call(.cleanup, payload: payload), method: .cleanup)
  }

  /// The agent answers and then takes the OS down, so the connection dying right after the reply
  /// is the expected outcome rather than a failure.
  public func shutdown() async throws {
    do {
      _ = try await call(.shutdown, allowReconnect: false)
    } catch GuestAgentError.transportClosed {
      return
    }
  }

  /// Streams `agent.exec`. Chunks arrive in emission order; `.exited` arrives exactly once, last.
  /// Cancelling the returned stream sends a `cancel` envelope, which the agent answers with
  /// `CANCELLED` after killing the process group.
  public func exec(_ request: ExecRequest) async throws -> AsyncThrowingStream<ExecEvent, any Error> {
    let connection = try await connection()
    let payload = try GuestCoding.payload(request)
    let chunks = connection.stream(method: GuestMethod.exec.rawValue, payload: payload)
    return AsyncThrowingStream<ExecEvent, any Error> { continuation in
      let task = Task { await GuestAgentClient.pump(chunks, into: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func pump(
    _ chunks: AsyncThrowingStream<JSONValue, any Error>,
    into continuation: AsyncThrowingStream<ExecEvent, any Error>.Continuation
  ) async {
    do {
      for try await value in chunks {
        // The terminal payload carries `exitCode`; every other chunk is output.
        if value["exitCode"] != nil {
          let result = try GuestCoding.decode(ExecResult.self, from: value)
          continuation.yield(.exited(Int32(clamping: result.exitCode)))
        } else {
          continuation.yield(ExecEvent(chunk: try GuestCoding.decode(ExecChunk.self, from: value)))
        }
      }
      continuation.finish()
    } catch let error as RPCCallError {
      continuation.finish(throwing: GuestAgentClient.translate(error, method: .exec))
    } catch {
      continuation.finish(throwing: error)
    }
  }

  // MARK: - Readiness

  /// Polls `agent.hello` + `agent.health` until the agent reports `ready`, the deadline elapses or
  /// the task is cancelled. Retryable failures (no bridge, closed connection, request timeout)
  /// drop the connection and try again on a fresh vsock dial; anything else fails immediately.
  @discardableResult
  public func waitUntilReady(
    timeout: Duration, policy: ReadinessPolicy = ReadinessPolicy()
  ) async throws -> HelloResponse {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var backoff = policy.initialBackoff
    var lastReason = "no answer from the agent bridge yet"
    while true {
      try Task.checkCancellation()
      do {
        let hello = try await hello()
        let health = try await health()
        if health.isReady { return hello }
        lastReason = Self.describe(health)
      } catch let error as GuestAgentError {
        guard error.retryable else { throw error }
        lastReason = error.message
        await drop()
      }
      let remaining = clock.now.duration(to: deadline)
      guard remaining > .zero else {
        throw GuestAgentError.readinessTimeout(seconds: timeout.seconds, lastReason: lastReason)
      }
      try await Task.sleep(for: min(backoff, remaining), clock: clock)
      backoff = min(backoff * policy.multiplier, policy.maxBackoff)
    }
  }

  private static func describe(_ health: HealthResponse) -> String {
    let state = "health is \(health.state.rawValue)"
    return health.reasons.isEmpty ? state : "\(state) (\(health.reasons.joined(separator: "; ")))"
  }

  // MARK: - Transport

  private func connection() async throws -> RPCClient {
    guard !closed else {
      throw GuestAgentError.transportClosed(reason: "guest client for \(name) is closed")
    }
    if let client { return client }
    do {
      let fresh = try await RPCClient.connect(
        protocol: .guest, socketPath: socketPath, limits: limits)
      client = fresh
      return fresh
    } catch {
      throw GuestAgentError.notReady(reason: "\(name) is not accepting connections: \(error)")
    }
  }

  private func drop() async {
    let previous = client
    client = nil
    await previous?.close()
  }

  private func call(
    _ method: GuestMethod, payload: JSONValue? = nil, allowReconnect: Bool = true
  ) async throws -> JSONValue {
    let connection = try await connection()
    do {
      return try await connection.call(
        method: method.rawValue, payload: payload, deadline: callDeadline)
    } catch let error as RPCCallError {
      if case .cancelled = error { throw CancellationError() }
      // The bridge closes the connection when the guest has no agent yet, so one silent redial
      // separates "still booting" from "answered and failed".
      if case .disconnected = error {
        await drop()
        if allowReconnect {
          return try await call(method, payload: payload, allowReconnect: false)
        }
      }
      throw Self.translate(error, method: method)
    }
  }

  private func decode<T: Decodable>(
    _ type: T.Type, from payload: JSONValue, method: GuestMethod
  ) throws -> T {
    do {
      return try GuestCoding.decode(type, from: payload)
    } catch {
      throw GuestAgentError.methodFailed(
        method: method.rawValue, reason: "undecodable result: \(error)")
    }
  }

  private nonisolated var name: String { socketPath.lastPathComponent }

  static func translate(_ error: RPCCallError, method: GuestMethod) -> GuestAgentError {
    switch error {
    case .remote(let payload):
      return .methodFailed(method: method.rawValue, reason: "\(payload.code): \(payload.message)")
    case .disconnected:
      return .transportClosed(reason: "guest closed the connection during \(method.rawValue)")
    case .deadlineExceeded:
      return .requestTimeout(method: method.rawValue)
    case .cancelled:
      return .transportClosed(reason: "\(method.rawValue) was cancelled")
    case .tooManyInFlight:
      return .methodFailed(method: method.rawValue, reason: "local in-flight budget exhausted")
    case .protocolViolation(let reason):
      return .handshakeFailed(reason: reason)
    }
  }
}

extension Duration {
  /// Seconds as a `Double`, for error messages that quote a deadline.
  var seconds: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
