import CryptoKit
import Foundation
import ImageStore
import Logging
import Persistence
import RPC
import RunnerCore
import RunnerLogging
import WorkerProtocol

/// What runnerd can currently prove about one worker (plan C1 "Worker fencing / reconnect").
/// `lockHeldNoSocket` is deliberately not `dead`: a worker that has taken its lock but not yet
/// published its socket is starting, and killing it would race a healthy boot.
public enum WorkerLiveness: String, Sendable, Hashable {
  case connected
  case lockHeldNoSocket
  case dead
}

/// "Is a vmworker holding this instance's `worker.lock`?" — the one liveness signal runnerd can
/// trust, because the kernel releases an `fcntl` lock when the holder dies and a pid cannot be
/// trusted the same way. `InstanceStore` is the production implementation.
public protocol WorkerLockProbe: Sendable {
  func workerLockHolder(instanceId: InstanceID) async throws -> pid_t?
}

extension InstanceStore: WorkerLockProbe {}

/// The proven identity of one worker incarnation. Every field was checked against the row runnerd
/// wrote before the spawn, so `pid` here is the only pid the supervisor may ever signal.
public struct WorkerSession: Sendable, Hashable {
  public var instanceId: InstanceID
  public var generation: Int
  public var nonce: String
  public var specDigest: String
  public var pid: Int32
  public var vmState: WorkerVMState
  public var socketPath: URL
}

public enum WorkerSupervisorError: RunnerError {
  case fencingMismatch(instance: InstanceID, field: String, expected: String, actual: String)
  case socketTimeout(instance: InstanceID, seconds: Double)
  case workerGone(instance: InstanceID)
  case notConnected(instance: InstanceID)
  case alreadySupervised(instance: InstanceID)

  public var code: String {
    switch self {
    case .fencingMismatch: "VM_WORKER_FENCED"
    case .socketTimeout, .workerGone: "VM_WORKER_SPAWN_FAILED"
    case .notConnected: "VM_WORKER_UNRESPONSIVE"
    case .alreadySupervised: "VM_WORKER_ALREADY_RUNNING"
    }
  }

  public var message: String {
    switch self {
    case let .fencingMismatch(instance, field, expected, actual):
      "worker for \(instance) reported \(field) '\(actual)', expected '\(expected)'"
    case let .socketTimeout(instance, seconds):
      "worker for \(instance) published no socket within \(seconds)s"
    case let .workerGone(instance):
      "the worker for \(instance) exited before runnerd could connect; see worker.log in the "
        + "instance directory"
    case let .notConnected(instance):
      "no worker connection for \(instance)"
    case let .alreadySupervised(instance):
      "a worker for \(instance) is already supervised"
    }
  }

  public var retryable: Bool {
    switch self {
    case .socketTimeout, .workerGone: true
    case .fencingMismatch, .notConnected, .alreadySupervised: false
    }
  }
}

/// Owns every live runnerd ⇄ vmworker connection: spawn, fencing handshake, lease renewal, VM
/// state events, and reconnect after a daemon restart.
public actor WorkerSupervisor {
  public typealias StateHandler = @Sendable (InstanceID, WorkerVMState) async -> Void
  public typealias DisconnectHandler = @Sendable (InstanceID) async -> Void

  public struct Tuning: Sendable {
    public var leaseTTLMs: Int64 = 30_000
    /// ttl/3, per Proto/worker_protocol.md.
    public var leaseInterval: Duration = .seconds(10)
    public var socketPollInterval: Duration = .milliseconds(100)
    public var socketPollAttempts: Int = 300
    /// Attempts before "no socket and no lock" is read as a dead worker rather than a slow one.
    public var lockGraceAttempts: Int = 20
    public var reconnectPollAttempts: Int = 20
    public var callDeadline: Duration = .seconds(30)

    public init() {}
  }

  private struct Connection {
    let client: RPCClient
    let hello: HelloResponse
    var vmState: WorkerVMState
    var leaseTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
  }

  private let paths: RunnerPaths
  private let launcher: any WorkerLauncher
  private let store: any WorkerLockProbe
  private let instances: any InstanceRepository
  private let tuning: Tuning
  private let logger: Logger

  private var connections: [InstanceID: Connection] = [:]
  private var spawnedPids: [InstanceID: Int32] = [:]
  private var onState: StateHandler = { _, _ in }
  private var onDisconnect: DisconnectHandler = { _ in }

  public init(
    paths: RunnerPaths, launcher: any WorkerLauncher, store: any WorkerLockProbe,
    instances: any InstanceRepository, tuning: Tuning = Tuning(),
    logger: Logger = Logger(component: .workerSupervisor)
  ) {
    self.paths = paths
    self.launcher = launcher
    self.store = store
    self.instances = instances
    self.tuning = tuning
    self.logger = logger
  }

  /// Installed after construction because the instance manager and the supervisor refer to each
  /// other; the manager exists only once the supervisor does.
  public func setHandlers(onState: @escaping StateHandler, onDisconnect: @escaping DisconnectHandler) {
    self.onState = onState
    self.onDisconnect = onDisconnect
  }

  // MARK: - Spawn

  /// Bumps the fencing generation, spawns a detached worker and completes the handshake. The
  /// generation is incremented only after the lock is proven unheld, so a live worker for this
  /// instance can never be fenced out from under itself.
  public func start(instance: InstanceRecord, specPath: URL) async throws -> WorkerSession {
    let id = instance.id
    guard connections[id] == nil else { throw WorkerSupervisorError.alreadySupervised(instance: id) }
    if let holder = await lockHolder(id) {
      throw VMError.workerLockHeldByOtherProcess(
        path: "\(paths.instanceDir(id).path(percentEncoded: false))/worker.lock (pid \(holder))")
    }
    let digest = try Self.specDigest(at: specPath)
    let nonce = Self.randomNonce()
    let generation = try await instances.bumpWorkerGeneration(
      id: id, nonce: nonce, specDigest: digest)
    let socket = paths.workerSocket(id)
    // Safe now that the lock is proven unheld: whatever published this socket is gone.
    try? FileManager.default.removeItem(at: socket)

    let handle = try await launcher.launch(
      WorkerLaunchRequest(
        instanceId: id, specPath: specPath, socketDir: paths.socketDir, generation: generation,
        nonce: nonce, logPath: paths.instanceDir(id).appending(path: VMInstanceLayout.workerLogName)))
    spawnedPids[id] = handle.pid
    logger.info(
      "worker spawned",
      metadata: .context(instance: id, workerPID: handle.pid)
        .merging(["generation": .stringConvertible(generation)]) { $1 })
    return try await connect(
      id: id, generation: generation, nonce: nonce, specDigest: digest, socket: socket,
      attempts: tuning.socketPollAttempts)
  }

  // MARK: - Reconnect

  /// Startup recovery: adopt every worker that still holds its instance lock, and report the rest
  /// as dead so the caller can move those instances to `interrupted`.
  public func reconnectAll(instances records: [InstanceRecord]) async -> [InstanceID: WorkerLiveness] {
    var result: [InstanceID: WorkerLiveness] = [:]
    for record in records where record.workerGeneration > 0 && record.state.consumesCapacity {
      result[record.id] = await reconnect(record)
    }
    return result
  }

  private func reconnect(_ record: InstanceRecord) async -> WorkerLiveness {
    let id = record.id
    if connections[id] != nil { return .connected }
    guard await lockHolder(id) != nil else { return .dead }
    guard let nonce = record.incarnationNonce, let digest = record.specDigest else {
      logger.warning("worker row has no fencing material", metadata: .context(instance: id))
      return .dead
    }
    do {
      let session = try await connect(
        id: id, generation: record.workerGeneration, nonce: nonce, specDigest: digest,
        socket: paths.workerSocket(id), attempts: tuning.reconnectPollAttempts)
      logger.info(
        "worker reconnected",
        metadata: .context(instance: id, workerPID: session.pid)
          .merging(["generation": .stringConvertible(session.generation)]) { $1 })
      return .connected
    } catch {
      logger.warning(
        "worker reconnect failed",
        metadata: .context(instance: id).merging(["error": .string("\(error)")]) { $1 })
      return .lockHeldNoSocket
    }
  }

  // MARK: - Handshake

  private func connect(
    id: InstanceID, generation: Int, nonce: String, specDigest: String, socket: URL, attempts: Int
  ) async throws -> WorkerSession {
    for attempt in 0..<attempts {
      if FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)),
         let client = try? await RPCClient.connect(protocol: .worker, socketPath: socket) {
        do {
          return try await handshake(
            client: client, id: id, generation: generation, nonce: nonce, specDigest: specDigest,
            socket: socket)
        } catch {
          await client.close()
          throw error
        }
      }
      if attempt >= tuning.lockGraceAttempts, await lockHolder(id) == nil {
        throw WorkerSupervisorError.workerGone(instance: id)
      }
      try? await Task.sleep(for: tuning.socketPollInterval)
    }
    let seconds = Double(attempts) * Double(tuning.socketPollInterval.milliseconds) / 1000
    throw WorkerSupervisorError.socketTimeout(instance: id, seconds: seconds)
  }

  private func handshake(
    client: RPCClient, id: InstanceID, generation: Int, nonce: String, specDigest: String,
    socket: URL
  ) async throws -> WorkerSession {
    let payload = try await client.call(
      method: WorkerMethod.hello.rawValue, deadline: tuning.callDeadline)
    let hello = try WorkerCoding.decode(HelloResponse.self, from: payload)
    try Self.verify(hello, id: id, generation: generation, nonce: nonce, specDigest: specDigest)

    var connection = Connection(client: client, hello: hello, vmState: hello.vmState)
    connection.leaseTask = leaseLoop(id: id, client: client)
    connection.eventTask = eventLoop(id: id, client: client)
    connections[id] = connection
    return WorkerSession(
      instanceId: id, generation: hello.generation, nonce: hello.incarnationNonce,
      specDigest: hello.specDigest, pid: hello.pid, vmState: hello.vmState, socketPath: socket)
  }

  /// Every field is compared exactly: a worker that disagrees on any of them belongs to a previous
  /// incarnation (or another instance) and must never be driven.
  private static func verify(
    _ hello: HelloResponse, id: InstanceID, generation: Int, nonce: String, specDigest: String
  ) throws {
    func check(_ field: String, _ expected: String, _ actual: String) throws {
      guard expected == actual else {
        throw WorkerSupervisorError.fencingMismatch(
          instance: id, field: field, expected: expected, actual: actual)
      }
    }
    try check("instanceId", id.rawValue, hello.instanceId.rawValue)
    try check("generation", String(generation), String(hello.generation))
    try check("incarnationNonce", nonce, hello.incarnationNonce)
    try check("specDigest", specDigest, hello.specDigest)
    try check(
      "protocolVersion", String(WorkerProtocolVersion.current), String(hello.protocolVersion))
  }

  // MARK: - Background loops

  private func leaseLoop(id: InstanceID, client: RPCClient) -> Task<Void, Never> {
    let interval = tuning.leaseInterval
    let payload = try? WorkerCoding.payload(LeaseRequest(ttlMs: tuning.leaseTTLMs))
    let deadline = tuning.callDeadline
    return Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        do {
          _ = try await client.call(
            method: WorkerMethod.lease.rawValue, payload: payload, deadline: deadline)
        } catch {
          await self?.dropConnection(id: id, reason: "lease renewal failed: \(error)")
          return
        }
      }
    }
  }

  private func eventLoop(id: InstanceID, client: RPCClient) -> Task<Void, Never> {
    Task { [weak self] in
      for await envelope in client.events {
        guard envelope.kind == .event, let method = envelope.method else { continue }
        await self?.handle(event: method, payload: envelope.payload, id: id)
      }
      await self?.dropConnection(id: id, reason: "worker closed the connection", fromEventLoop: true)
    }
  }

  private func handle(event: String, payload: JSONValue?, id: InstanceID) async {
    switch event {
    case WorkerEvent.vmStateChanged.rawValue:
      guard let decoded = try? WorkerCoding.decode(VMStateChangedEvent.self, from: payload) else {
        return
      }
      connections[id]?.vmState = decoded.vmState
      logger.debug(
        "vm state",
        metadata: .context(instance: id).merging(["vm_state": .string(decoded.vmState.rawValue)]) { $1 })
      await onState(id, decoded.vmState)
    case WorkerEvent.vmError.rawValue:
      let decoded = try? WorkerCoding.decode(VMErrorEvent.self, from: payload)
      logger.error(
        "vm error",
        metadata: .context(instance: id)
          .merging(["error": .string(decoded?.message ?? "unknown")]) { $1 })
    default:
      break
    }
  }

  /// `fromEventLoop` matters: cancelling the task that is running this call would poison every
  /// `await` inside `onDisconnect` (GRDB reads throw on cancellation), silently swallowing the
  /// interruption the daemon must record.
  private func dropConnection(id: InstanceID, reason: String, fromEventLoop: Bool = false) async {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.leaseTask?.cancel()
    if !fromEventLoop { connection.eventTask?.cancel() }
    await connection.client.close()
    logger.warning(
      "worker connection lost",
      metadata: .context(instance: id).merging(["reason": .string(reason)]) { $1 })
    await onDisconnect(id)
  }

  // MARK: - Commands

  public func startVM(id: InstanceID) async throws -> WorkerVMState {
    try await callState(id: id, method: .vmStart)
  }

  public func forceStop(id: InstanceID) async throws -> WorkerVMState {
    try await callState(id: id, method: .vmForceStop)
  }

  public func requestStop(id: InstanceID) async throws -> Bool {
    let payload = try await call(id: id, method: .vmRequestStop, payload: nil)
    return try WorkerCoding.decode(RequestStopResponse.self, from: payload).accepted
  }

  /// `drain` lets a busy runner finish; `stop` takes the VM down now. Either way the worker
  /// answers first and exits on its own — runnerd never signals it.
  public func shutdown(
    id: InstanceID, reason: ShutdownRequest.Reason, gracefulTimeoutMs: Int64 = 30_000
  ) async throws {
    let request = ShutdownRequest(reason: reason, gracefulTimeoutMs: gracefulTimeoutMs)
    _ = try await call(id: id, method: .shutdown, payload: try WorkerCoding.payload(request))
    await detach(id: id)
  }

  /// Forgets a connection without reporting a disconnect: used when runnerd itself asked the
  /// worker to exit, so the instance manager must not read it as an interruption.
  public func detach(id: InstanceID) async {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.leaseTask?.cancel()
    connection.eventTask?.cancel()
    await connection.client.close()
  }

  /// Daemon teardown: drop the connections but leave the workers running (that is the whole point
  /// of a detached session — see spike S2).
  public func detachAll() async {
    for id in Array(connections.keys) { await detach(id: id) }
  }

  private func callState(id: InstanceID, method: WorkerMethod) async throws -> WorkerVMState {
    let payload = try await call(id: id, method: method, payload: nil)
    let state = try WorkerCoding.decode(VMStateResponse.self, from: payload).vmState
    connections[id]?.vmState = state
    return state
  }

  private func call(
    id: InstanceID, method: WorkerMethod, payload: JSONValue?
  ) async throws -> JSONValue {
    guard let connection = connections[id] else {
      throw WorkerSupervisorError.notConnected(instance: id)
    }
    return try await connection.client.call(
      method: method.rawValue, payload: payload, deadline: tuning.callDeadline)
  }

  // MARK: - Introspection

  public func session(id: InstanceID) -> WorkerSession? {
    guard let connection = connections[id] else { return nil }
    return WorkerSession(
      instanceId: id, generation: connection.hello.generation,
      nonce: connection.hello.incarnationNonce, specDigest: connection.hello.specDigest,
      pid: connection.hello.pid, vmState: connection.vmState, socketPath: paths.workerSocket(id))
  }

  public func state(id: InstanceID) -> WorkerVMState? { connections[id]?.vmState }

  public var connectedCount: Int { connections.count }

  public func liveness(id: InstanceID) async -> WorkerLiveness {
    if connections[id] != nil { return .connected }
    return await lockHolder(id) != nil ? .lockHeldNoSocket : .dead
  }

  /// An unreadable lock file is reported as unheld: the file is created at materialization and
  /// only a missing instance directory can make this fail, which is itself proof of no worker.
  private func lockHolder(_ id: InstanceID) async -> pid_t? {
    do {
      return try await store.workerLockHolder(instanceId: id)
    } catch {
      logger.debug(
        "worker lock unreadable",
        metadata: .context(instance: id).merging(["error": .string("\(error)")]) { $1 })
      return nil
    }
  }

  /// Detached workers are still our children, so their exit status has to be collected or they
  /// linger as zombies. After a daemon restart they are not ours at all: `ECHILD` is expected.
  public func reapExitedChildren() {
    for (id, pid) in spawnedPids {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        spawnedPids.removeValue(forKey: id)
        logger.info(
          "worker process reaped",
          metadata: .context(instance: id, workerPID: pid)
            .merging(["exit_status": .stringConvertible(status)]) { $1 })
      } else if result < 0, errno == ECHILD {
        spawnedPids.removeValue(forKey: id)
      }
    }
  }

  public func forget(id: InstanceID) async {
    await detach(id: id)
    spawnedPids.removeValue(forKey: id)
  }

  // MARK: - Fencing material

  /// Taken over the bytes on disk, because that is what vmworker hashes (`SpecDigest`).
  static func specDigest(at url: URL) throws -> String {
    do {
      let data = try Data(contentsOf: url)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    } catch {
      throw VMError.specInvalid(reason: "cannot read \(url.path(percentEncoded: false)): \(error)")
    }
  }

  static func randomNonce() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }
}
