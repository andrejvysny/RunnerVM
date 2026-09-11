import Darwin
import Foundation
import ProcessSpawn
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
  /// SIGTERM-to-SIGKILL window for the shutdowns the worker starts on its own (hard deadline,
  /// orphan idle, SIGTERM), where no `worker.shutdown` request carries one. The instance profile's
  /// `timeouts.gracefulShutdown`; the default matches vmworker's own.
  public var gracefulShutdownMs: Int64

  public init(
    instanceId: InstanceID, specPath: URL, socketDir: URL, generation: Int, nonce: String,
    logPath: URL, gracefulShutdownMs: Int64 = 30_000
  ) {
    self.instanceId = instanceId
    self.specPath = specPath
    self.socketDir = socketDir
    self.generation = generation
    self.nonce = nonce
    self.logPath = logPath
    self.gracefulShutdownMs = gracefulShutdownMs
  }

  var arguments: [String] {
    [
      "run",
      "--instance", instanceId.rawValue,
      "--spec", specPath.path(percentEncoded: false),
      "--socket-dir", socketDir.path(percentEncoded: false),
      "--generation", String(generation),
      "--nonce", nonce,
      "--graceful-ms", String(gracefulShutdownMs),
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
/// in runnerd's terminal process group, `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps the daemon's SQLite
/// handles, listening sockets and lock descriptors out of a process that may outlive it, and
/// `POSIX_SPAWN_SETSIGDEF`/`SETSIGMASK` undo runnerd's own `SIG_IGN` dispositions -- an ignored
/// disposition survives `exec`, so without them a worker inherits "ignore SIGTERM" from the
/// daemon and `WorkerSupervisor`'s graceful stop is dead code (`SpawnAttributes`).
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
    var actions = try FileActions.make(logPath: request.logPath)
    defer { actions.destroy() }
    var attributes: SpawnAttributes
    do {
      attributes = try SpawnAttributes(placement: .ownSession)
    } catch {
      throw VMError.workerSpawnFailed(reason: "posix_spawnattr_init failed", cause: nil)
    }
    defer { attributes.destroy() }

    var pid: pid_t = 0
    let argv = [path] + request.arguments
    // Allowlisted, not inherited: runnerd's environment carries GitHub/registry credentials the
    // worker must never see. Sorted for a deterministic argv across runs.
    let environment = WorkerEnvironment.build(from: ProcessInfo.processInfo.environment)
    let status = withCStrings(argv) { cArgv in
      withCStrings(environmentPairs(environment)) { cEnv in
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
private enum FileActions {
  static func make(logPath: URL) throws -> SpawnFileActions {
    var actions: SpawnFileActions
    do {
      actions = try SpawnFileActions()
    } catch {
      throw VMError.workerSpawnFailed(reason: "posix_spawn_file_actions_init failed", cause: nil)
    }
    let log = logPath.path(percentEncoded: false)
    actions.open(0, path: "/dev/null", flags: O_RDONLY, mode: 0)
    actions.open(1, path: log, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
    actions.duplicate(1, onto: 2)
    return actions
  }
}
