import Darwin
import Foundation

/// One external command to run, with every bound that makes it finish stated up front.
///
/// The environment is part of the request because `posix_spawn` does not inherit one: a caller
/// that forgets it hands the child an *empty* environment, and a `set -u` script reading `$HOME`
/// then dies in a way no exit code explains. `defaultEnvironment()` is the same allowlist
/// `WorkerEnvironment` uses for `vmworker` -- runnerd's own environment carries GitHub and
/// registry credentials that no helper it shells out to has any business seeing.
public struct SpawnRequest: Sendable {
  /// Absolute path. `posix_spawn` (not `posix_spawnp`) is used, so `PATH` never resolves argv[0].
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  /// Written to the child's stdin, which is then closed. `nil` gives the child `/dev/null`.
  public var standardInput: String?
  /// Wall clock from spawn to `SIGTERM` on the child's process group.
  public var timeout: Duration
  /// Grace between that `SIGTERM` and the `SIGKILL` that follows it.
  public var killGrace: Duration
  /// How long the pipes are still read after the leader exits, for output a process that outlived
  /// its own group leader is still writing. Also the ceiling on such a reader: past it the fds are
  /// closed and whatever was captured is returned.
  public var drainGrace: Duration
  /// Bytes retained per stream, at each end. Everything is still streamed through `onOutput`;
  /// this only caps what travels back in `SpawnResult` (a 40-minute transcript is not an error
  /// message).
  public var captureLimit: Int

  public init(
    executable: String, arguments: [String] = [], environment: [String: String]? = nil,
    standardInput: String? = nil, timeout: Duration, killGrace: Duration = .seconds(10),
    drainGrace: Duration = .seconds(5), captureLimit: Int = 256 << 10
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment ?? Self.defaultEnvironment()
    self.standardInput = standardInput
    self.timeout = timeout
    self.killGrace = killGrace
    self.drainGrace = drainGrace
    self.captureLimit = captureLimit
  }

  /// Exact names, never prefix-matched: an unlisted variable never crosses into a child, even one
  /// that happens to share a prefix with an entry here. Mirrors `WorkerEnvironment.allowedVariables`
  /// (Orchestration cannot be imported from this leaf target, so the list is restated).
  public static let allowedVariables: [String] = [
    "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
  ]

  /// Used only when `parent` has no `PATH` at all, so a helper can still resolve its own tools.
  static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  public static func defaultEnvironment(
    from parent: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var result: [String: String] = [:]
    for key in allowedVariables where parent[key] != nil {
      result[key] = parent[key]
    }
    if result["PATH"] == nil { result["PATH"] = fallbackPath }
    // A LaunchDaemon session may start runnerd with no `HOME` at all, and a `set -u` helper that
    // defaults an output directory to `$HOME/...` then fails before it does anything.
    if result["HOME"] == nil, let home = passwdHomeDirectory() { result["HOME"] = home }
    return result
  }

  static func passwdHomeDirectory(uid: uid_t = geteuid()) -> String? {
    guard let entry = getpwuid(uid), let dir = entry.pointee.pw_dir else { return nil }
    let home = String(cString: dir)
    return home.isEmpty ? nil : home
  }
}

/// What one `SpawnRequest` produced.
public struct SpawnResult: Sendable, Hashable {
  /// `WIFEXITED ? WEXITSTATUS : 128 + WTERMSIG`, or `-1` when the status could not be collected
  /// at all (`waitpid` answered `ECHILD` -- something else reaped the child). Never a raw
  /// `waitpid` status: `256` meaning "exited 1" has been read as a success by more than one
  /// caller.
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  /// The wall-clock ceiling fired and the process group was signalled. `exitCode` is then whatever
  /// the leader died of, which for a process that handles `SIGTERM` can still be `0`.
  public var timedOut: Bool
  /// The calling task was cancelled, so the process group was signalled for that reason instead.
  /// Callers check this *before* `timedOut` and before any exit code: a cancelled build is
  /// cancelled, not failed, and recording it as a tool timeout loses that distinction.
  public var cancelled: Bool
  /// Output was longer than `captureLimit` allows, so `stdout`/`stderr` have a middle section
  /// elided. Only the retained text is affected; `onOutput` saw everything.
  public var outputTruncated: Bool
  /// The leader's pid, which is also its process group id (`POSIX_SPAWN_SETPGROUP` with pgroup 0).
  public var pid: pid_t
  public var pgid: pid_t

  public init(
    exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
    cancelled: Bool = false, outputTruncated: Bool = false, pid: pid_t = 0, pgid: pid_t = 0
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.cancelled = cancelled
    self.outputTruncated = outputTruncated
    self.pid = pid
    self.pgid = pgid
  }
}
