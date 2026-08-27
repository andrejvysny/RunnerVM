import Foundation
import RPC
import RunnerCore
import WorkerProtocol

@testable import Orchestration

/// An in-process stand-in for `vmworker run`: a real `RPCServer` on the `worker` protocol, so the
/// supervisor exercises its actual transport, handshake and event path.
actor FakeWorker {
  struct Script: Sendable {
    var generation: Int
    var nonce: String
    var specDigest: String
    var instanceId: InstanceID
    var vmState: WorkerVMState = .starting
    /// States broadcast (in order) once `vm.start` is called.
    var statesAfterStart: [WorkerVMState] = [.running]
    var protocolVersion: Int = WorkerProtocolVersion.current
  }

  private let server: RPCServer
  private let socketPath: URL
  private var script: Script
  private var shutdownCount = 0
  private var onExit: @Sendable () async -> Void = {}

  init(socketPath: URL, script: Script) {
    self.socketPath = socketPath
    self.script = script
    self.server = RPCServer(protocol: .worker, socketPath: socketPath, allowedUIDs: [getuid()])
  }

  /// The real worker answers `worker.shutdown` and then exits; the launcher uses this to drop the
  /// lock it reports for this instance.
  func setExitHandler(_ handler: @escaping @Sendable () async -> Void) {
    onExit = handler
  }

  func start() async throws {
    await register()
    try await server.start()
  }

  func stop() async {
    await server.stop()
    try? FileManager.default.removeItem(at: socketPath)
  }

  var shutdownRequests: Int { shutdownCount }

  var currentState: WorkerVMState { script.vmState }

  /// Pushes an unsolicited `vm.stateChanged`, exactly as the real worker does.
  func emit(_ state: WorkerVMState) async {
    script.vmState = state
    await server.broadcast(
      event: WorkerEvent.vmStateChanged.rawValue,
      payload: try? WorkerCoding.payload(VMStateChangedEvent(vmState: state, at: Date())))
  }

  private func register() async {
    await server.register(method: WorkerMethod.hello.rawValue, class: .readOnly) { [self] _, _ in
      try WorkerCoding.payload(await hello())
    }
    await server.register(method: WorkerMethod.lease.rawValue, class: .idempotentMutation) { _, _ in
      try WorkerCoding.payload(LeaseResponse(leaseExpiresAt: Date().addingTimeInterval(30)))
    }
    await server.register(method: WorkerMethod.vmStart.rawValue, class: .idempotentMutation) {
      [self] _, _ in try WorkerCoding.payload(VMStateResponse(vmState: await startVM()))
    }
    await server.register(method: WorkerMethod.vmState.rawValue, class: .readOnly) { [self] _, _ in
      try WorkerCoding.payload(VMStateResponse(vmState: await currentState))
    }
    await server.register(method: WorkerMethod.vmForceStop.rawValue, class: .idempotentMutation) {
      [self] _, _ in
      await emit(.stopped)
      return try WorkerCoding.payload(VMStateResponse(vmState: .stopped))
    }
    await server.register(method: WorkerMethod.shutdown.rawValue, class: .singleShot) { [self] _, _ in
      await recordShutdown()
      return .emptyObject
    }
  }

  private func hello() -> HelloResponse {
    HelloResponse(
      instanceId: script.instanceId, generation: script.generation,
      incarnationNonce: script.nonce, specDigest: script.specDigest, pid: getpid(),
      protocolVersion: script.protocolVersion, vmState: script.vmState)
  }

  private func startVM() async -> WorkerVMState {
    for state in script.statesAfterStart { await emit(state) }
    return script.vmState
  }

  private func recordShutdown() {
    shutdownCount += 1
    let handler = onExit
    Task { await handler() }
  }
}

/// `WorkerLauncher` that starts a `FakeWorker` instead of a process, and a `WorkerLockProbe` that
/// reports the lock as held for exactly as long as that fake worker is serving.
actor FakeWorkerLauncher: WorkerLauncher, WorkerLockProbe {
  struct Behaviour: Sendable {
    /// Reported by `worker.hello` instead of the generation runnerd asked for.
    var generationOverride: Int?
    var nonceOverride: String?
    var specDigestOverride: String?
    var statesAfterStart: [WorkerVMState] = [.running]
    /// Publish no socket at all, as if the worker died during startup.
    var failToPublish = false

    init() {}
  }

  private let paths: RunnerPaths
  private var behaviour: Behaviour
  private var workers: [InstanceID: FakeWorker] = [:]
  private var pids: [InstanceID: Int32] = [:]
  private var nextPid: Int32 = 4_100

  init(paths: RunnerPaths, behaviour: Behaviour = Behaviour()) {
    self.paths = paths
    self.behaviour = behaviour
  }

  func set(_ behaviour: Behaviour) {
    self.behaviour = behaviour
  }

  func worker(for id: InstanceID) -> FakeWorker? { workers[id] }

  /// Simulates `kill -9` on the worker: the socket goes away and the lock is released.
  func killWorker(_ id: InstanceID) async {
    guard let worker = workers.removeValue(forKey: id) else { return }
    pids.removeValue(forKey: id)
    await worker.stop()
  }

  /// Stops every worker still tracked, e.g. one a test launched and never explicitly killed or
  /// shut down. Test teardown calls this before removing the temp tree the workers' sockets live
  /// in, so nothing is still bound inside it when the directory goes away.
  func stopAll() async {
    for worker in workers.values { await worker.stop() }
    workers.removeAll()
    pids.removeAll()
  }

  // MARK: - WorkerLauncher

  func launch(_ request: WorkerLaunchRequest) async throws -> WorkerHandle {
    nextPid += 1
    let pid = nextPid
    guard !behaviour.failToPublish else {
      return WorkerHandle(pid: pid)
    }
    let digest = try WorkerSupervisor.specDigest(at: request.specPath)
    // From `request.socketDir`, not `paths.socketDir`: an image build's worker publishes under
    // `<socketDir>/build/` so it cannot collide with an instance that shares its short id.
    try? FileManager.default.createDirectory(
      at: request.socketDir, withIntermediateDirectories: true)
    let worker = FakeWorker(
      socketPath: Self.socket(in: request.socketDir, for: request.instanceId),
      script: FakeWorker.Script(
        generation: behaviour.generationOverride ?? request.generation,
        nonce: behaviour.nonceOverride ?? request.nonce,
        specDigest: behaviour.specDigestOverride ?? digest,
        instanceId: request.instanceId,
        statesAfterStart: behaviour.statesAfterStart))
    try await worker.start()
    let id = request.instanceId
    await worker.setExitHandler { [weak self] in await self?.killWorker(id) }
    workers[id] = worker
    pids[id] = pid
    return WorkerHandle(pid: pid)
  }

  /// Where `RunnerPaths.workerSocket`/`buildWorkerSocket` put a worker's control socket, given
  /// whichever namespace the request named.
  static func socket(in directory: URL, for id: InstanceID) -> URL {
    directory.appending(path: "vm-\(RunnerPaths.shortID(id)).sock")
  }

  // MARK: - WorkerLockProbe

  /// `fcntl` locks are per-process, so a real lock taken here would look unheld to the probe in the
  /// same process. The fake worker's presence is the equivalent signal.
  func workerLockHolder(instanceId: InstanceID) async throws -> pid_t? {
    pids[instanceId]
  }
}
