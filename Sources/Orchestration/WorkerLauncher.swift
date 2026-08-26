import Darwin
import Foundation
import RunnerCore

/// What runnerd tells a fresh `vmworker run` about the incarnation it is starting.
public struct WorkerLaunchRequest: Sendable, Hashable {
  public var instanceId: InstanceID
  public var specPath: URL
  public var socketDir: URL
  public var generation: Int
  public var nonce: String
  /// stdout+stderr are appended here; the worker outlives runnerd, so it cannot inherit its pipes.
  public var logPath: URL

  public init(
    instanceId: InstanceID, specPath: URL, socketDir: URL, generation: Int, nonce: String,
    logPath: URL
  ) {
    self.instanceId = instanceId
    self.specPath = specPath
    self.socketDir = socketDir
    self.generation = generation
    self.nonce = nonce
    self.logPath = logPath
  }

  var arguments: [String] {
    [
      "run",
      "--instance", instanceId.rawValue,
      "--spec", specPath.path(percentEncoded: false),
      "--socket-dir", socketDir.path(percentEncoded: false),
      "--generation", String(generation),
      "--nonce", nonce,
    ]
  }
}

/// The pid is only ever used together with a successful fencing handshake: a pid on its own proves
/// nothing (it can be recycled), which is why the supervisor never signals one it did not verify.
public struct WorkerHandle: Sendable, Hashable {
  public var pid: Int32

  public init(pid: Int32) {
    self.pid = pid
  }
}

public protocol WorkerLauncher: Sendable {
  func launch(_ request: WorkerLaunchRequest) async throws -> WorkerHandle
}

/// `posix_spawn` launcher for the real `vmworker` binary.
///
/// The child gets its own session (`POSIX_SPAWN_SETSID`) so it survives runnerd's exit and is not
/// in runnerd's terminal process group, and `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps the daemon's
/// SQLite handles, listening sockets and lock descriptors out of a process that may outlive it.
public struct ProcessWorkerLauncher: WorkerLauncher {
  private let executable: URL

  public init(executable: URL) {
    self.executable = executable
  }

  /// `RUNNERVM_VMWORKER`, else a sibling of the running executable — the same lookup the host
  /// probe uses, so one override points both at a test stub.
  public static func resolveExecutable(_ override: URL?) -> URL? {
    override ?? HostProbe.defaultExecutable()
  }

  public func launch(_ request: WorkerLaunchRequest) async throws -> WorkerHandle {
    let path = executable.path(percentEncoded: false)
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw VMError.workerSpawnFailed(reason: "\(path) is not executable", cause: nil)
    }
    var actions = try FileActions(logPath: request.logPath)
    defer { actions.destroy() }
    var attributes = SpawnAttributes()
    defer { attributes.destroy() }

    var pid: pid_t = 0
    let argv = [path] + request.arguments
    // Allowlisted, not inherited: runnerd's environment carries GitHub/registry credentials the
    // worker must never see. Sorted for a deterministic argv across runs.
    let environment = WorkerEnvironment.build(from: ProcessInfo.processInfo.environment)
    let envPairs = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let status = withCStrings(argv) { cArgv in
      withCStrings(envPairs) { cEnv in
        posix_spawn(&pid, path, &actions.value, &attributes.value, cArgv, cEnv)
      }
    }
    guard status == 0 else {
      throw VMError.workerSpawnFailed(
        reason: "posix_spawn(\(path)): \(String(cString: strerror(status)))", cause: nil)
    }
    return WorkerHandle(pid: pid)
  }
}

// MARK: - posix_spawn plumbing

/// stdin from `/dev/null`, stdout+stderr appended to `worker.log`. Opened by the child so a
/// failure to create the log is the child's problem, not a half-spawned worker.
private struct FileActions {
  var value = posix_spawn_file_actions_t(bitPattern: 0)

  init(logPath: URL) throws {
    guard posix_spawn_file_actions_init(&value) == 0 else {
      throw VMError.workerSpawnFailed(reason: "posix_spawn_file_actions_init failed", cause: nil)
    }
    let log = logPath.path(percentEncoded: false)
    posix_spawn_file_actions_addopen(&value, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&value, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&value, 1, 2)
  }

  mutating func destroy() {
    posix_spawn_file_actions_destroy(&value)
  }
}

private struct SpawnAttributes {
  var value = posix_spawnattr_t(bitPattern: 0)

  init() {
    posix_spawnattr_init(&value)
    let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&value, Int16(flags))
  }

  mutating func destroy() {
    posix_spawnattr_destroy(&value)
  }
}

/// `posix_spawn` wants a NULL-terminated `char *const []`; the buffers must outlive the call, so
/// the body runs inside the allocation rather than returning the pointers.
private func withCStrings<T>(
  _ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
  var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
  pointers.append(nil)
  defer { for pointer in pointers where pointer != nil { free(pointer) } }
  return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
