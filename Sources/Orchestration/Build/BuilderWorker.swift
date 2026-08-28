import CryptoKit
import Darwin
import Foundation
import ImageStore
import Logging
import RPC
import RunnerCore
import RunnerLogging
import WorkerProtocol

/// One builder VM's `vmworker`: spawn, fencing handshake, lease renewal, shutdown.
///
/// Deliberately *not* `WorkerSupervisor`. That actor owns the instance fleet -- a `[InstanceID:
/// Connection]` map, reconnect-after-restart, disconnect callbacks that move instance rows to
/// `interrupted`. A build owns exactly one worker for the length of one `Task`, has no row in
/// `instances` for the supervisor's bookkeeping to key on, publishes its socket in its own
/// namespace (`<socketDir>/build/`, B8), and is never adopted across a daemon restart: recovery
/// terminates it instead. Sharing the supervisor would mean teaching it a second identity type and
/// a second recovery policy for no reuse beyond the ~30 lines of handshake below.
public actor BuilderWorker {
  public struct Options: Sendable {
    public var buildId: ImageBuildID
    public var specPath: URL
    public var socketDir: URL
    public var socket: URL
    public var logPath: URL
    public var leaseTTLMs: Int64
    public var leaseInterval: Duration
    public var callDeadline: Duration
    public var socketPollInterval: Duration
    public var socketPollAttempts: Int

    public init(
      buildId: ImageBuildID, specPath: URL, socketDir: URL, socket: URL, logPath: URL,
      leaseTTLMs: Int64 = 30_000, leaseInterval: Duration = .seconds(10),
      callDeadline: Duration = .seconds(30), socketPollInterval: Duration = .milliseconds(100),
      socketPollAttempts: Int = 300
    ) {
      self.buildId = buildId
      self.specPath = specPath
      self.socketDir = socketDir
      self.socket = socket
      self.logPath = logPath
      self.leaseTTLMs = leaseTTLMs
      self.leaseInterval = leaseInterval
      self.callDeadline = callDeadline
      self.socketPollInterval = socketPollInterval
      self.socketPollAttempts = socketPollAttempts
    }
  }

  private let options: Options
  private let logger: Logger
  private var client: RPCClient?
  private var leaseTask: Task<Void, Never>?
  private var session: (pid: Int32, nonce: String)?

  public init(options: Options, logger: Logger = Logger(component: .workerSupervisor)) {
    self.options = options
    self.logger = logger
  }

  public var workerPID: Int32? { session?.pid }
  public var nonce: String? { session?.nonce }
  public var isConnected: Bool { client != nil }

  // MARK: - Launch

  /// Spawns `vmworker run` for this build and completes the fencing handshake. Generation is always
  /// 1: a build's VM is never restarted in place, so there is no second incarnation to fence out.
  @discardableResult
  public func launch(launcher: any WorkerLauncher) async throws -> Int32 {
    let digest = try Self.specDigest(at: options.specPath)
    let nonce = Self.randomNonce()
    try FileManager.default.createDirectory(at: options.socketDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: options.socketDir.path(percentEncoded: false))
    // Nothing holds this build's lock yet (the directory was created moments ago), so a leftover
    // socket file can only be debris.
    try? FileManager.default.removeItem(at: options.socket)

    let handle = try await launcher.launch(
      WorkerLaunchRequest(
        instanceId: InstanceID(rawValue: options.buildId.rawValue), specPath: options.specPath,
        socketDir: options.socketDir, generation: 1, nonce: nonce, logPath: options.logPath))
    let hello = try await connect(nonce: nonce, specDigest: digest)
    session = (hello.pid, nonce)
    leaseTask = leaseLoop()
    logger.info(
      "build worker spawned",
      metadata: [
        "build_id": .string(options.buildId.rawValue),
        "worker_pid": .stringConvertible(handle.pid),
      ])
    return hello.pid
  }

  private func connect(nonce: String, specDigest: String) async throws -> HelloResponse {
    for _ in 0..<options.socketPollAttempts {
      if FileManager.default.fileExists(atPath: options.socket.path(percentEncoded: false)),
         let client = try? await RPCClient.connect(protocol: .worker, socketPath: options.socket) {
        do {
          let hello = try await Self.hello(client: client, deadline: options.callDeadline)
          try Self.verify(
            hello, buildId: options.buildId, generation: 1, nonce: nonce, specDigest: specDigest)
          self.client = client
          return hello
        } catch {
          await client.close()
          throw error
        }
      }
      // Cancellation propagates: a build that is being cancelled must not keep polling for a
      // socket that will never matter.
      try await Task.sleep(for: options.socketPollInterval)
    }
    throw ImageBuildError.agentUnreachable(
      reason: "vmworker published no socket at \(options.socket.lastPathComponent)")
  }

  /// Every field is compared exactly, as `WorkerSupervisor.verify` does: a worker that disagrees on
  /// any of them belongs to something else and must never be driven.
  static func verify(
    _ hello: HelloResponse, buildId: ImageBuildID, generation: Int, nonce: String, specDigest: String
  ) throws {
    func check(_ field: String, _ expected: String, _ actual: String) throws {
      guard expected == actual else {
        throw WorkerSupervisorError.fencingMismatch(
          instance: InstanceID(rawValue: buildId.rawValue), field: field, expected: expected,
          actual: actual)
      }
    }
    try check("instanceId", buildId.rawValue, hello.instanceId.rawValue)
    try check("generation", String(generation), String(hello.generation))
    try check("incarnationNonce", nonce, hello.incarnationNonce)
    try check("specDigest", specDigest, hello.specDigest)
    try check(
      "protocolVersion", String(WorkerProtocolVersion.current), String(hello.protocolVersion))
  }

  // MARK: - Commands

  @discardableResult
  public func startVM() async throws -> WorkerVMState {
    let payload = try await call(.vmStart, payload: nil)
    return try WorkerCoding.decode(VMStateResponse.self, from: payload).vmState
  }

  /// What the worker says its VM is doing right now.
  ///
  /// Polled rather than event-driven, unlike the instance path: a build owns exactly one worker
  /// for the length of one `Task` and has no `WorkerSupervisor` subscription to hang a
  /// `vm.stateChanged` handler off, so the one caller that needs to notice a guest halting itself
  /// (a macOS provisioning run, D7) asks.
  public func vmState() async throws -> WorkerVMState {
    let payload = try await call(.vmState, payload: nil)
    return try WorkerCoding.decode(VMStateResponse.self, from: payload).vmState
  }

  /// The worker answers and then exits on its own; runnerd never signals it. A transport failure
  /// here means it already went away, which is the outcome we wanted.
  public func shutdown(gracefulTimeoutMs: Int64) async {
    let request = ShutdownRequest(reason: .stop, gracefulTimeoutMs: gracefulTimeoutMs)
    _ = try? await call(.shutdown, payload: try? WorkerCoding.payload(request))
    await detach()
  }

  public func detach() async {
    leaseTask?.cancel()
    leaseTask = nil
    await client?.close()
    client = nil
  }

  private func call(_ method: WorkerMethod, payload: JSONValue?) async throws -> JSONValue {
    guard let client else {
      throw WorkerSupervisorError.notConnected(
        instance: InstanceID(rawValue: options.buildId.rawValue))
    }
    return try await client.call(
      method: method.rawValue, payload: payload, deadline: options.callDeadline)
  }

  private func leaseLoop() -> Task<Void, Never> {
    let interval = options.leaseInterval
    let payload = try? WorkerCoding.payload(LeaseRequest(ttlMs: options.leaseTTLMs))
    let deadline = options.callDeadline
    guard let client else { return Task {} }
    let logger = logger
    let buildId = options.buildId
    return Task {
      while !Task.isCancelled {
        // Cancellation is the normal way this loop ends (teardown cancels it); a lease RPC that
        // fails is not, so it is logged: from here on the worker ages out on its own lease TTL.
        do { try await Task.sleep(for: interval) } catch { return }
        do {
          _ = try await client.call(
            method: WorkerMethod.lease.rawValue, payload: payload, deadline: deadline)
        } catch {
          logger.warning(
            "build worker lease renewal failed; the worker will expire on its own",
            metadata: [
              "build_id": .string(buildId.rawValue), "error": .string(String(describing: error)),
            ])
          return
        }
      }
    }
  }

  // MARK: - Exit

  /// Waits for the kernel to release the worker's `fcntl` lock -- the only proof the process is
  /// gone. Returns `false` on timeout, and the caller must then leave the directory alone: hashing
  /// or deleting a disk under a live vmworker is how a torn image gets published.
  public static func waitForExit(
    lock: URL, interval: Duration = .milliseconds(100), attempts: Int = 600
  ) async -> Bool {
    for _ in 0..<attempts {
      if (try? WorkerLock.holderPID(at: lock)) ?? nil == nil { return true }
      // A cancelled waiter has no proof of death: answer `false`, which every caller treats as
      // "leave the directory alone".
      do { try await Task.sleep(for: interval) } catch { return false }
    }
    return ((try? WorkerLock.holderPID(at: lock)) ?? nil) == nil
  }

  /// Restart recovery (B8): find out what happened to a worker left behind by a previous daemon,
  /// without ever signalling it. The released `fcntl` lock is the only proof of death this daemon
  /// accepts -- a pid can be recycled, a lock cannot -- so a holder whose identity `worker.hello`
  /// cannot establish is logged, left running, and reported as `.unverifiable`: deleting files
  /// under an unknown live process is exactly the failure mode fencing exists to prevent.
  ///
  /// `exitWait` is short by design. This runs inside the serial reconcile tick, and a worker that
  /// has not released its lock within it is handled by keeping the build pending, never by
  /// blocking the tick until it does.
  public static func probeOrphan(
    lock: URL, socket: URL, expectedBuildId: ImageBuildID, expectedNonce: String?,
    gracefulTimeoutMs: Int64 = 30_000,
    exitWait: (interval: Duration, attempts: Int) = (.milliseconds(100), 50),
    logger: Logger
  ) async -> OrphanVerdict {
    guard ((try? WorkerLock.holderPID(at: lock)) ?? nil) != nil else { return .noHolder }
    guard FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)),
          let client = try? await RPCClient.connect(protocol: .worker, socketPath: socket),
          let hello = try? await hello(client: client, deadline: .seconds(10))
    else {
      logger.warning(
        "build worker identity could not be established; leaving it alone",
        metadata: ["build_id": .string(expectedBuildId.rawValue)])
      return .unverifiable(reason: "no verifiable socket")
    }
    defer { Task { await client.close() } }
    guard hello.instanceId.rawValue == expectedBuildId.rawValue,
          expectedNonce == nil || hello.incarnationNonce == expectedNonce
    else {
      logger.warning(
        "build worker socket belongs to another incarnation; leaving it alone",
        metadata: [
          "build_id": .string(expectedBuildId.rawValue),
          "reported": .string(hello.instanceId.rawValue),
        ])
      return .unverifiable(reason: "foreign worker")
    }
    let request = ShutdownRequest(reason: .stop, gracefulTimeoutMs: gracefulTimeoutMs)
    _ = try? await client.call(
      method: WorkerMethod.shutdown.rawValue, payload: try? WorkerCoding.payload(request),
      deadline: .seconds(30))
    let released = await waitForExit(
      lock: lock, interval: exitWait.interval, attempts: exitWait.attempts)
    return released ? .exited : .stillRunning(shutdownSent: true)
  }

  private static func hello(client: RPCClient, deadline: Duration) async throws -> HelloResponse {
    let payload = try await client.call(method: WorkerMethod.hello.rawValue, deadline: deadline)
    return try WorkerCoding.decode(HelloResponse.self, from: payload)
  }

  // MARK: - Fencing material

  /// Taken over the bytes on disk, because that is what vmworker hashes.
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

/// What `BuilderWorker.probeOrphan` learned about a builder worker nobody in this process owns.
///
/// Only `.noHolder` and `.exited` are proof the VM is gone. Everything the build reserved -- host
/// capacity, the base-image pin, the build directory -- stays committed for the other two, because
/// releasing any of it while a vmworker may still be writing is how a torn image gets published.
public enum OrphanVerdict: Sendable, Equatable {
  /// Nobody holds the build's `worker.lock`: the worker is gone.
  case noHolder
  /// The worker was verified, asked to shut down, and released its lock within the bounded wait.
  case exited
  /// The lock is still held after the bounded wait. `shutdownSent` records whether this daemon
  /// managed to ask it to stop -- it never signals the process either way.
  case stillRunning(shutdownSent: Bool)
  /// A lock holder that could not be tied to this build: no socket to speak to, or a `worker.hello`
  /// naming another build or incarnation.
  case unverifiable(reason: String)

  /// The kernel released the lock, which is the only death proof runnerd accepts.
  public var isProvenDead: Bool {
    switch self {
    case .noHolder, .exited: true
    case .stillRunning, .unverifiable: false
    }
  }

  /// One short phrase for the pending log line and the `build cancel` refusal.
  public var reason: String {
    switch self {
    case .noHolder: "no lock holder"
    case .exited: "exited after shutdown"
    case let .stillRunning(shutdownSent):
      shutdownSent ? "still holding its lock after shutdown" : "still holding its lock"
    case let .unverifiable(reason): reason
    }
  }
}
