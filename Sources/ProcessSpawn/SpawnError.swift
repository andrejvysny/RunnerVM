import Darwin

/// Everything that can go wrong *before* a child is running.
///
/// Nothing that happens after a successful `posix_spawn` is an error here: the process ran, and
/// how it ended -- an exit code, a signal, a timeout, unreadable output -- is data on
/// `SpawnResult`. `ProcessSpawn` deliberately has no dependency on `RunnerCore`, so this is a
/// plain `Error`; each caller maps it into its own module's error type (`ImageBuildError`,
/// `SetupError`) at the seam where it knows what the executable was for.
public enum SpawnError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The path does not exist, is not a file, or is not executable by this process.
  case executableMissing(path: String)
  /// `pipe(2)`/`fcntl(2)` failed while setting the child's stdio up. Practically always `EMFILE`.
  case pipeFailed(code: Int32)
  /// `posix_spawn(2)` itself failed. `code` is its *return value* (an errno number), not `errno`.
  case spawnFailed(path: String, code: Int32)

  public var description: String {
    switch self {
    case let .executableMissing(path):
      "\(path) is not an executable file"
    case let .pipeFailed(code):
      "could not create the child's pipes: \(String(cString: strerror(code)))"
    case let .spawnFailed(path, code):
      "posix_spawn(\(path)): \(String(cString: strerror(code)))"
    }
  }
}
