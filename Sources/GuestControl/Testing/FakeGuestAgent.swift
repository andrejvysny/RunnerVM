import Foundation
import RPC

/// In-process stand-in for the Go guest agent: a real ``RPCServer`` on the `guest` protocol bound
/// to a Unix socket, so callers exercise the actual framing, envelope and streaming paths.
///
/// Test support, deliberately shipped in the product module rather than in a test target: the
/// daemon tests in `OrchestrationTests` need it too, and SwiftPM test targets cannot import each
/// other. Nothing in the daemon may construct one.
public actor FakeGuestAgent {
  /// One step of a scripted `agent.exec`.
  public enum ExecStep: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
  }

  /// Everything the fake answers. Mutable after construction through the `set…` methods so a test
  /// can flip a guest from `starting` to `ready` without racing a background timer.
  public struct Script: Sendable {
    public var hello: HelloResponse
    /// Answered in order; the final entry repeats for every later call.
    public var health: [HealthResponse]
    public var info: GuestInfo
    public var metrics: GuestMetrics
    public var resizeDisk: ResizeDiskResponse
    public var exec: [ExecStep]
    public var runnerStatus: RunnerStatus
    /// Walked one entry per `agent.runnerStatus` call, sticking on the last — the way a real
    /// runner moves `starting -> online -> busy -> exited` without the test racing a timer.
    /// `nil` answers every call with `runnerStatus`.
    public var runnerStatusSequence: [RunnerStatus]?
    /// Registers the session and *then* fails, modelling a reply that never made it back to
    /// runnerd: the runner is live but the caller does not know it.
    public var startRunnerFailsAfterStart: RPCErrorPayload?
    public var startRunnerPid: Int64
    public var cleanup: CleanupResponse
    /// Methods that answer with a wire error instead of a result.
    public var failures: [GuestMethod: RPCErrorPayload]

    public init(
      hello: HelloResponse = Script.defaultHello,
      health: [HealthResponse] = [HealthResponse(state: .ready)],
      info: GuestInfo = Script.defaultInfo,
      metrics: GuestMetrics = Script.defaultMetrics,
      resizeDisk: ResizeDiskResponse = ResizeDiskResponse(grown: true, rootBytes: 42 << 30),
      exec: [ExecStep] = [.stdout("ok\n"), .exit(0)],
      runnerStatus: RunnerStatus = RunnerStatus(state: .online, pid: 4_242),
      runnerStatusSequence: [RunnerStatus]? = nil,
      startRunnerFailsAfterStart: RPCErrorPayload? = nil,
      startRunnerPid: Int64 = 4_242,
      cleanup: CleanupResponse = CleanupResponse(ok: true, removed: []),
      failures: [GuestMethod: RPCErrorPayload] = [:]
    ) {
      self.hello = hello
      self.health = health
      self.info = info
      self.metrics = metrics
      self.resizeDisk = resizeDisk
      self.exec = exec
      self.runnerStatus = runnerStatus
      self.runnerStatusSequence = runnerStatusSequence
      self.startRunnerFailsAfterStart = startRunnerFailsAfterStart
      self.startRunnerPid = startRunnerPid
      self.cleanup = cleanup
      self.failures = failures
    }

    /// Boots `starting` for `attempts` polls and then reports `ready`.
    public static func slowStart(attempts: Int, bootId: String = defaultHello.bootId) -> Script {
      var script = Script()
      script.hello.bootId = bootId
      script.health =
        Array(repeating: HealthResponse(state: .starting, reasons: ["runner user missing"]),
              count: max(0, attempts)) + [HealthResponse(state: .ready)]
      return script
    }

    /// Never reaches `ready`; used to exercise the `AGENT_READY_TIMEOUT` path.
    public static func neverReady(reason: String = "docker is not running") -> Script {
      var script = Script()
      script.health = [HealthResponse(state: .starting, reasons: [reason])]
      return script
    }
  }

  private let server: RPCServer
  private let socketPath: URL
  private var script: Script
  private var healthIndex = 0
  private var runnerStatusIndex = 0
  private var startedSessions: Set<String> = []
  private var stoppedSessions: Set<String> = []
  private var appliedEpochs: Set<Int64> = []
  private var counters: [GuestMethod: Int] = [:]
  private var lastExecRequest: ExecRequest?
  private var lastStartRunnerSessionId: String?
  private var started = false

  public init(socketPath: URL, script: Script = Script()) {
    self.socketPath = socketPath
    self.script = script
    self.server = RPCServer(protocol: .guest, socketPath: socketPath, allowedUIDs: [getuid()])
  }

  public func start() async throws {
    guard !started else { return }
    await register()
    try await server.start()
    started = true
  }

  public func stop() async {
    guard started else { return }
    started = false
    await server.stop()
    try? FileManager.default.removeItem(at: socketPath)
  }

  // MARK: - Test control

  public func set(_ script: Script) {
    self.script = script
    healthIndex = 0
  }

  public func setHealth(_ health: [HealthResponse]) {
    script.health = health
    healthIndex = 0
  }

  public func setExec(_ steps: [ExecStep]) { script.exec = steps }

  public func setMetrics(_ metrics: GuestMetrics) { script.metrics = metrics }

  public func setInfo(_ info: GuestInfo) { script.info = info }

  public func setBootId(_ bootId: String) { script.hello.bootId = bootId }

  public func setRunnerStatus(_ status: RunnerStatus) {
    script.runnerStatus = status
    script.runnerStatusSequence = nil
  }

  public func setRunnerStatusSequence(_ statuses: [RunnerStatus]) {
    script.runnerStatusSequence = statuses
    runnerStatusIndex = 0
  }

  public func fail(_ method: GuestMethod, with error: RPCErrorPayload) {
    script.failures[method] = error
  }

  public func callCount(_ method: GuestMethod) -> Int { counters[method] ?? 0 }

  public func lastExec() -> ExecRequest? { lastExecRequest }

  /// The `sessionId` of the last `agent.startRunner`. The `jitConfig` it carried is deliberately
  /// not retained: nothing outside the agent process ever needs to see it again.
  public func lastRunnerSession() -> String? { lastStartRunnerSessionId }

  public func runningSessions() -> Set<String> { startedSessions.subtracting(stoppedSessions) }

  public func cleanupEpochs() -> Set<Int64> { appliedEpochs }

  // MARK: - Handlers

  private func register() async {
    await unary(.hello) { [self] _ in try GuestCoding.payload(await nextHello()) }
    await unary(.health) { [self] _ in try GuestCoding.payload(await nextHealth()) }
    await unary(.getInfo) { [self] _ in try GuestCoding.payload(await currentInfo()) }
    await unary(.getMetrics) { [self] _ in try GuestCoding.payload(await currentMetrics()) }
    await unary(.resizeDisk) { [self] _ in try GuestCoding.payload(await currentResize()) }
    await unary(.startRunner) { [self] envelope in
      try GuestCoding.payload(
        try await startRunner(GuestCoding.decode(StartRunnerRequest.self, from: envelope.payload)))
    }
    await unary(.runnerStatus) { [self] envelope in
      let request = try GuestCoding.decode(RunnerStatusRequest.self, from: envelope.payload)
      return try GuestCoding.payload(await status(of: request.sessionId))
    }
    await unary(.stopRunner) { [self] envelope in
      let request = try GuestCoding.decode(StopRunnerRequest.self, from: envelope.payload)
      return try GuestCoding.payload(await stopRunner(sessionId: request.sessionId))
    }
    await unary(.cleanup) { [self] envelope in
      let request = try GuestCoding.decode(CleanupRequest.self, from: envelope.payload)
      return try GuestCoding.payload(await cleanup(epoch: request.epoch))
    }
    await unary(.shutdown) { _ in .emptyObject }
    await server.registerStream(
      method: GuestMethod.exec.rawValue, class: GuestMethod.exec.methodClass
    ) { [self] envelope, _, sink in
      try await runExec(envelope, sink: sink)
    }
  }

  private func unary(
    _ method: GuestMethod, _ body: @escaping @Sendable (Envelope) async throws -> JSONValue
  ) async {
    await server.register(method: method.rawValue, class: method.methodClass) { [self] envelope, _ in
      try await reject(method)
      return try await body(envelope)
    }
  }

  private func reject(_ method: GuestMethod) throws {
    count(method)
    if let failure = script.failures[method] { throw RPCCallError.remote(failure) }
  }

  private func count(_ method: GuestMethod) {
    counters[method, default: 0] += 1
  }

  private func nextHello() -> HelloResponse { script.hello }

  /// Walks the health script one entry per call and then sticks on the last answer.
  private func nextHealth() -> HealthResponse {
    guard !script.health.isEmpty else { return HealthResponse(state: .ready) }
    let response = script.health[min(healthIndex, script.health.count - 1)]
    healthIndex += 1
    return response
  }

  private func currentInfo() -> GuestInfo { script.info }

  private func currentMetrics() -> GuestMetrics { script.metrics }

  private func currentResize() -> ResizeDiskResponse { script.resizeDisk }

  private func startRunner(_ request: StartRunnerRequest) throws -> StartRunnerResponse {
    guard startedSessions.insert(request.sessionId).inserted else {
      throw RPCCallError.remote(
        RPCErrorPayload(
          code: GuestErrorCode.alreadyStarted,
          message: "session \(request.sessionId) is already started"))
    }
    lastStartRunnerSessionId = request.sessionId
    if let failure = script.startRunnerFailsAfterStart { throw RPCCallError.remote(failure) }
    return StartRunnerResponse(
      pid: script.startRunnerPid, startedAt: GuestCoding.timestamp(from: Date()))
  }

  private func status(of sessionId: String) -> RunnerStatus {
    guard startedSessions.contains(sessionId) else { return RunnerStatus(state: .unknown) }
    if stoppedSessions.contains(sessionId) {
      return RunnerStatus(
        state: .exited, pid: script.runnerStatus.pid, exitCode: 0,
        exitedAt: GuestCoding.timestamp(from: Date()))
    }
    guard let sequence = script.runnerStatusSequence, !sequence.isEmpty else {
      return script.runnerStatus
    }
    let status = sequence[min(runnerStatusIndex, sequence.count - 1)]
    runnerStatusIndex += 1
    return status
  }

  private func stopRunner(sessionId: String) -> StopRunnerResponse {
    guard startedSessions.contains(sessionId) else { return StopRunnerResponse(stopped: true) }
    stoppedSessions.insert(sessionId)
    return StopRunnerResponse(stopped: true)
  }

  private func cleanup(epoch: Int64) -> CleanupResponse {
    guard appliedEpochs.insert(epoch).inserted else { return CleanupResponse(ok: true, removed: []) }
    return script.cleanup
  }

  private func runExec(_ envelope: Envelope, sink: StreamSink) async throws {
    try reject(.exec)
    lastExecRequest = try? GuestCoding.decode(ExecRequest.self, from: envelope.payload)
    for step in script.exec {
      switch step {
      case .stdout(let text):
        try await sink.send(
          GuestCoding.payload(ExecChunk(stream: .stdout, data: Data(text.utf8))))
      case .stderr(let text):
        try await sink.send(
          GuestCoding.payload(ExecChunk(stream: .stderr, data: Data(text.utf8))))
      case .exit(let code):
        try await sink.send(GuestCoding.payload(ExecResult(exitCode: Int64(code))))
      }
    }
  }
}

extension FakeGuestAgent.Script {
  public static let defaultHello = HelloResponse(
    agentVersion: "0.1.0-test", os: "linux", arch: "arm64", hostname: "rvm-test",
    bootId: "6f1a2b3c-4d5e-4f60-871a-2b3c4d5e6f70",
    capabilities: ["exec", "metrics", "resizeDisk"])

  public static let defaultInfo = GuestInfo(
    ipAddresses: ["192.168.64.7"], uptimeSec: 12, kernel: "6.8.0-31-generic",
    runnerVersion: "2.317.0", dockerVersion: "26.1.0")

  public static let defaultMetrics = GuestMetrics(
    timestamp: "2026-08-25T12:00:00Z", uptimeSec: 12,
    cpu: GuestMetrics.CPUMetrics(
      logicalCount: 2, usagePercent: 7.5, load1: 0.1, load5: 0.2, load15: 0.3),
    memory: GuestMetrics.MemoryMetrics(
      totalBytes: 2 << 30, usedBytes: 512 << 20, availableBytes: (2 << 30) - (512 << 20)),
    disk: GuestMetrics.DiskMetrics(
      rootTotalBytes: 40 << 30, rootUsedBytes: 4 << 30, rootAvailableBytes: 36 << 30),
    runner: GuestMetrics.RunnerMetrics(
      processRunning: false, pid: nil, cpuPercent: 0, rssBytes: 0))
}
