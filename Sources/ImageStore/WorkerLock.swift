import Darwin
import Foundation
import RunnerCore

/// `instances/<uuid>/worker.lock`. vmworker takes an `F_WRLCK` on it before building any VZ object
/// and the kernel drops it when that process dies, which makes it the one liveness signal runnerd
/// can trust — a PID can be recycled, a lock cannot.
enum WorkerLock {
  /// `F_GETLK` probe. Returns the holder's pid, or nil when nobody holds the lock (or the file does
  /// not exist, which means no worker ever ran here).
  static func holderPID(at url: URL) throws -> pid_t? {
    let path = url.path(percentEncoded: false)
    guard FileSystem.exists(url) else { return nil }
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else { throw FileSystem.posixError(errno, "open", path) }
    defer { close(descriptor) }

    var probe = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    let result = withUnsafeMutablePointer(to: &probe) { fcntl(descriptor, F_GETLK, $0) }
    guard result == 0 else { throw FileSystem.posixError(errno, "fcntl(F_GETLK)", path) }
    return probe.l_type == Int16(F_UNLCK) ? nil : probe.l_pid
  }

  static func requireUnheld(at url: URL) throws {
    if let holder = try holderPID(at: url) {
      throw VMError.workerLockHeldByOtherProcess(path: "\(url.path(percentEncoded: false)) (pid \(holder))")
    }
  }
}
