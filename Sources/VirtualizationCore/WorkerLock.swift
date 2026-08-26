import Foundation

public enum WorkerLockError: Error, CustomStringConvertible, Equatable {
  /// Another live process owns the instance. `pid` is the holder reported by `F_GETLK`.
  case held(pid: pid_t?)
  case posix(operation: String, errno: Int32)

  public var description: String {
    switch self {
    case .held(let pid): "instance lock held by pid \(pid.map(String.init) ?? "unknown")"
    case .posix(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
    }
  }
}

/// Exclusive ownership of one instance directory, so two vmworkers can never drive the same disk
/// image (Proto/worker_protocol.md: exit 75 when the lock is held).
///
/// The descriptor is deliberately never closed: POSIX record locks are per-process and are dropped
/// when *any* descriptor for the file is closed, so the lock lives exactly as long as the process.
public struct WorkerLock: Sendable {
  public let url: URL
  public let descriptor: CInt

  private init(url: URL, descriptor: CInt) {
    self.url = url
    self.descriptor = descriptor
  }

  /// Acquires `<instanceDirectory>/worker.lock`.
  public static func acquire(instanceDirectory: URL) throws -> WorkerLock {
    try acquire(url: VMRuntimePaths(directory: instanceDirectory).workerLock)
  }

  public static func acquire(url: URL) throws -> WorkerLock {
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw WorkerLockError.posix(operation: "open", errno: errno) }
    var request = lockRequest(type: F_WRLCK)
    guard fcntl(descriptor, F_SETLK, &request) == 0 else {
      let failure = errno
      close(descriptor)
      guard failure == EAGAIN || failure == EACCES else {
        throw WorkerLockError.posix(operation: "fcntl(F_SETLK)", errno: failure)
      }
      throw WorkerLockError.held(pid: holder(of: url))
    }
    // Record the owner so `ps`-free diagnosis is possible; truncate first, pids shrink.
    _ = ftruncate(descriptor, 0)
    let line = Array("\(getpid())\n".utf8)
    _ = line.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!, $0.count, 0) }
    return WorkerLock(url: url, descriptor: descriptor)
  }

  /// The pid currently holding the lock, or nil when the file is unlocked or unreadable.
  ///
  /// Returns nil when the calling process is itself the holder: `F_GETLK` answers "could *this*
  /// process take the lock", and a process never conflicts with its own record locks.
  public static func holder(of url: URL) -> pid_t? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var probe = lockRequest(type: F_WRLCK)
    guard fcntl(descriptor, F_GETLK, &probe) == 0 else { return nil }
    guard probe.l_type != Int16(F_UNLCK) else { return nil }
    return probe.l_pid
  }

  private static func lockRequest(type: Int32) -> flock {
    flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(type), l_whence: Int16(SEEK_SET))
  }
}
