import Dispatch
import Foundation
import Logging
import RPC
import RunnerCore
import VirtualizationCore
import WorkerProtocol

extension WorkerVMState {
  /// Exhaustive on purpose: the two enums live in targets that cannot import each other, so the
  /// compiler is the only thing that can keep them in step.
  init(_ state: VMRunState) {
    switch state {
    case .stopped: self = .stopped
    case .starting: self = .starting
    case .running: self = .running
    case .stopping: self = .stopping
    case .error: self = .error
    }
  }
}

/// Everything one `vmworker run` invocation owns: the VM, the two sockets, the lease clock and the
/// orphan policy. Pinned to the main actor because that is the queue the VM was created with.
@MainActor
final class WorkerService {
  struct Options: Sendable {
    var instanceId: InstanceID
    var generation: Int
    var nonce: String
    var specDigest: String
    var workerSocket: URL
    var agentSocket: URL
    var orphanIdle: TimeInterval
    /// Grace lease granted at startup so runnerd has time to connect and start renewing.
    var initialLeaseTtlMs: Int64
    var hardDeadline: Date?
    var agentPort: UInt32 = HostConstants.guestAgentVsockPort
  }

  let options: Options
  let logger: Logger
  private let runtime: VMRuntime
  private let bridge: VsockBridge
  private let server: RPCServer
  private let startedAt = Date()

  private(set) var vmState: VMRunState = .stopped
  private(set) var leaseExpiresAt: Date?
  private(set) var lastError: String?
  private var orphanIdleSince: Date?
  private var stopping = false
  private var timer: DispatchSourceTimer?
  private var signalSources: [DispatchSourceSignal] = []
  private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  init(options: Options, runtime: VMRuntime, logger: Logger) {
    self.options = options
    self.runtime = runtime
    self.logger = logger
    self.server = RPCServer(
      protocol: .worker, socketPath: options.workerSocket, allowedUIDs: [getuid()])
    let port = options.agentPort
    self.bridge = VsockBridge(socketPath: options.agentSocket) {
      try await runtime.connectToGuest(port: port)
    }
    self.vmState = runtime.state
  }

  // MARK: - Lifecycle

  /// Publishes both sockets, boots the guest and arms the policy timers. Throws only for failures
  /// that must map to a documented exit code.
  func startServing() async throws {
    _ = renewLease(ttlMs: options.initialLeaseTtlMs)
    consumeRuntimeEvents()
    try await registerMethods()
    try await server.start()
    try bridge.start()
    logger.info("worker serving", metadata: [
      "socket": .string(options.workerSocket.path), "agent_socket": .string(options.agentSocket.path),
    ])
    installSignalHandlers()
    armPolicyTimer()
    do {
      try await runtime.start()
      logger.info("vm started", metadata: ["vm_state": .string(runtime.state.rawValue)])
    } catch {
      logger.error("vm start failed", metadata: ["error": .string("\(error)")])
      throw WorkerStartupError.vmStartFailed
    }
  }

  private func consumeRuntimeEvents() {
    Task { [runtime] in
      for await event in runtime.events {
        await self.handle(event)
      }
    }
  }

  private func handle(_ event: VMRuntimeEvent) async {
    switch event {
    case .stateChanged(let state):
      guard state != vmState else { return }
      vmState = state
      logger.info("vm state", metadata: ["vm_state": .string(state.rawValue)])
      await broadcastState(state)
    case .guestDidStop:
      logger.info("guest stopped")
      resumeStopWaiters()
    case .stoppedWithError(let message):
      lastError = message
      logger.error("vm stopped with error", metadata: ["error": .string(message)])
      await server.broadcast(
        event: WorkerEvent.vmError.rawValue,
        payload: try? WorkerCoding.payload(VMErrorEvent(code: "VM_ERROR", message: message)))
      resumeStopWaiters()
    }
  }

  private func broadcastState(_ state: VMRunState) async {
    let payload = try? WorkerCoding.payload(
      VMStateChangedEvent(vmState: WorkerVMState(state), at: Date()))
    await server.broadcast(event: WorkerEvent.vmStateChanged.rawValue, payload: payload)
    if state == .stopped || state == .error { resumeStopWaiters() }
  }

  // MARK: - Method bodies

  func hello() -> HelloResponse {
    HelloResponse(
      instanceId: options.instanceId, generation: options.generation,
      incarnationNonce: options.nonce, specDigest: options.specDigest, pid: getpid(),
      vmState: WorkerVMState(vmState))
  }

  func status() -> StatusResponse {
    StatusResponse(
      vmState: WorkerVMState(vmState),
      uptimeMs: Int64(Date().timeIntervalSince(startedAt) * 1000),
      leaseExpiresAt: leaseExpiresAt, bridgeConnections: bridge.activeConnections,
      lastError: lastError)
  }

  func renewLease(ttlMs: Int64) -> Date {
    let expiry = Date().addingTimeInterval(TimeInterval(max(0, ttlMs)) / 1000)
    leaseExpiresAt = expiry
    orphanIdleSince = nil
    return expiry
  }

  func startVM() async throws -> WorkerVMState {
    guard vmState == .stopped || vmState == .error else { return WorkerVMState(vmState) }
    try await runtime.start()
    vmState = runtime.state
    return WorkerVMState(vmState)
  }

  func requestStopVM() throws -> Bool {
    try runtime.requestStop()
  }

  func forceStopVM() async throws -> WorkerVMState {
    try await runtime.forceStop()
    vmState = runtime.state
    return WorkerVMState(vmState)
  }

  func bridgeStatus() -> BridgeStatusResponse {
    BridgeStatusResponse(
      socketPath: options.agentSocket.path, activeConnections: bridge.activeConnections)
  }

  var currentState: WorkerVMState { WorkerVMState(vmState) }

  // MARK: - Shutdown

  /// Answers `worker.shutdown` immediately and tears down just after, so the caller still receives
  /// its response on a socket this process is about to unlink.
  func scheduleShutdown(_ request: ShutdownRequest) {
    guard !stopping else { return }
    stopping = true
    logger.info("shutdown requested", metadata: [
      "reason": .string(request.reason.rawValue),
      "graceful_timeout_ms": .stringConvertible(request.gracefulTimeoutMs),
    ])
    let timeout = request.gracefulTimeoutMs
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
      MainActor.assumeIsolated { self.launchShutdown(gracefulTimeoutMs: timeout) }
    }
  }

  private func launchShutdown(gracefulTimeoutMs: Int64) {
    Task { await self.performShutdown(gracefulTimeoutMs: gracefulTimeoutMs) }
  }

  func beginShutdown(reason: String, gracefulTimeoutMs: Int64) {
    guard !stopping else { return }
    stopping = true
    logger.info("stopping", metadata: ["reason": .string(reason)])
    Task { await self.performShutdown(gracefulTimeoutMs: gracefulTimeoutMs) }
  }

  private func performShutdown(gracefulTimeoutMs: Int64) async {
    timer?.cancel()
    timer = nil
    if vmState != .stopped {
      let accepted = (try? runtime.requestStop()) ?? false
      logger.info("acpi stop", metadata: ["accepted": .stringConvertible(accepted)])
      if accepted { await waitForStop(timeoutMs: gracefulTimeoutMs) }
      if vmState != .stopped {
        do { try await runtime.forceStop() } catch {
          logger.error("force stop failed", metadata: ["error": .string("\(error)")])
        }
      }
    }
    await teardown()
    logger.info("exit", metadata: ["code": .stringConvertible(0)])
    Foundation.exit(WorkerExitCode.clean.rawValue)
  }

  private func waitForStop(timeoutMs: Int64) async {
    guard vmState != .stopped else { return }
    let id = UUID()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      stopWaiters[id] = continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
        MainActor.assumeIsolated { self.resumeStopWaiter(id) }
      }
    }
  }

  private func resumeStopWaiters() {
    for id in stopWaiters.keys { resumeStopWaiter(id) }
  }

  private func resumeStopWaiter(_ id: UUID) {
    stopWaiters.removeValue(forKey: id)?.resume()
  }

  /// Sockets are unlinked here rather than left to the accept threads, which may not be scheduled
  /// again before `exit(2)`.
  private func teardown() async {
    bridge.stop()
    await server.stop()
    runtime.finishEvents()
    unlink(options.workerSocket.path)
    unlink(options.agentSocket.path)
  }

  // MARK: - Lease and orphan policy

  private func armPolicyTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
    timer.setEventHandler { MainActor.assumeIsolated { self.evaluatePolicy(now: Date()) } }
    timer.resume()
    self.timer = timer
  }

  /// A worker with no live lease must not outlive the daemon that spawned it. An absent lease
  /// counts as expired, so a worker whose daemon died before the first `worker.lease` still ages
  /// out through the idle path. `WorkerPolicy.decide` does the actual branching so it is testable
  /// on its own; this just applies the verdict.
  func evaluatePolicy(now: Date) {
    guard !stopping else { return }
    let result = WorkerPolicy.decide(
      now: now, hardDeadline: options.hardDeadline, leaseExpiresAt: leaseExpiresAt,
      activeConnections: bridge.activeConnections, orphanIdleSince: orphanIdleSince,
      orphanIdle: options.orphanIdle)
    orphanIdleSince = result.orphanIdleSince
    switch result.decision {
    case .none:
      break
    case .hardDeadline:
      beginShutdown(reason: "hard-deadline", gracefulTimeoutMs: 30_000)
    case .orphanIdle:
      beginShutdown(reason: "orphan-idle", gracefulTimeoutMs: 30_000)
    }
  }

  private func installSignalHandlers() {
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        MainActor.assumeIsolated {
          self.beginShutdown(reason: "signal-\(number)", gracefulTimeoutMs: 30_000)
        }
      }
      source.resume()
      signalSources.append(source)
    }
  }

  // MARK: - RPC wiring

  private func registerMethods() async throws {
    for method in WorkerMethod.allCases {
      await server.register(method: method.rawValue, class: method.methodClass) { envelope, _ in
        try await self.invoke(method, envelope: envelope)
      }
    }
  }
}

enum WorkerStartupError: Error {
  case vmStartFailed
}
