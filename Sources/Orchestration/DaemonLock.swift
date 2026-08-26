import Foundation
import Synchronization

/// Single-daemon guard (spec §69 step 1): an advisory `flock` on `<stateDir>/runnerd.lock` that
/// the kernel releases even if the process dies without unwinding.
public final class DaemonLock: Sendable {
  public let path: URL
  // `Mutex` rather than a plain `var` so `release()` cannot double-close the descriptor and the
  // type stays unconditionally `Sendable` without an `@unchecked` escape hatch.
  private let descriptor: Mutex<CInt?>

  private init(path: URL, descriptor: CInt) {
    self.path = path
    self.descriptor = Mutex(descriptor)
  }

  public static func acquire(at path: URL) throws -> DaemonLock {
    let filePath = path.path(percentEncoded: false)
    let fd = open(filePath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw OrchestrationError.lockUnavailable(path: filePath, errno: errno)
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let failure = errno
      close(fd)
      if failure == EWOULDBLOCK {
        throw OrchestrationError.daemonAlreadyRunning(path: filePath)
      }
      throw OrchestrationError.lockUnavailable(path: filePath, errno: failure)
    }
    Self.stampPID(fd)
    return DaemonLock(path: path, descriptor: fd)
  }

  /// Diagnostic only; the lock itself is the flock, not the file contents.
  private static func stampPID(_ fd: CInt) {
    _ = ftruncate(fd, 0)
    let bytes = Array("\(getpid())\n".utf8)
    _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
  }

  public func release() {
    descriptor.withLock { current in
      guard let fd = current else { return }
      _ = flock(fd, LOCK_UN)
      close(fd)
      current = nil
    }
  }

  deinit { release() }
}
