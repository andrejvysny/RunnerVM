import Darwin
import Foundation

enum AtomicFileWriteError: Error, CustomStringConvertible, Equatable {
  case posix(operation: String, errno: Int32, path: String)

  var description: String {
    switch self {
    case let .posix(operation, code, path):
      "\(operation) failed on \(path): \(String(cString: strerror(code)))"
    }
  }
}

/// Crash-safe replacement of a small secret file.
///
/// `FileManager.createFile` truncates the destination before writing it: a crash, a full disk or a
/// short write between the two leaves the GitHub PAT file empty or half-written, and the daemon
/// then cannot authenticate until an operator notices and runs `auth login` again. The sequence
/// below never has the destination in a partial state -- it is either the old token or the new
/// one:
///
///     unique temporary (O_EXCL, 0600) -> write-all -> fsync(file) -> rename -> fsync(directory)
///
/// A deliberate copy of `VirtualizationCore.DurableFile`, which `Orchestration` cannot import
/// (`VirtualizationCore` links Virtualization.framework and only `vmworker` may do that -- see
/// Package.swift's layering rules), and which cannot move down into `RunnerCore` because that
/// module is I/O-free by design.
enum AtomicFileWrite {
  /// Replaces `url` with `data`, or throws leaving the previous contents untouched. `mode` is
  /// applied to the temporary at creation, so the file is never briefly world-readable.
  static func replace(_ data: Data, at url: URL, mode: mode_t = 0o600) throws {
    let path = url.path(percentEncoded: false)
    let directory = url.deletingLastPathComponent()
    let (descriptor, temporaryPath) = try createTemporary(besides: url, mode: mode)
    var succeeded = false
    defer {
      close(descriptor)
      if !succeeded { unlink(temporaryPath) }
    }
    try writeAll(data, to: descriptor, path: temporaryPath)
    guard fsync(descriptor) == 0 else {
      throw AtomicFileWriteError.posix(operation: "fsync", errno: errno, path: temporaryPath)
    }
    guard rename(temporaryPath, path) == 0 else {
      throw AtomicFileWriteError.posix(operation: "rename", errno: errno, path: path)
    }
    succeeded = true
    // Best effort, like every other fsync-the-parent in the tree: the data is already durable and
    // the rename has happened, so a directory that cannot be opened is not a reason to fail.
    fsyncDirectory(directory)
  }

  /// `mkstemp(3)` semantics with a caller-chosen mode, in the destination's own directory so the
  /// later `rename(2)` cannot cross a filesystem boundary. A UUID rather than the pid: a pid
  /// repeats after a wrap, so a crashed run's leftover could be adopted by a later one.
  private static func createTemporary(besides url: URL, mode: mode_t) throws -> (CInt, String) {
    let directory = url.deletingLastPathComponent()
    for _ in 0..<8 {
      let name = "\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))"
      let candidate = directory.appendingPathComponent(name).path(percentEncoded: false)
      let descriptor = open(candidate, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
      if descriptor >= 0 {
        // `open(2)` applies the process umask to `mode`; a token file has to be 0600 whatever the
        // daemon's umask happens to be.
        guard fchmod(descriptor, mode) == 0 else {
          let failure = errno
          close(descriptor)
          unlink(candidate)
          throw AtomicFileWriteError.posix(operation: "fchmod", errno: failure, path: candidate)
        }
        return (descriptor, candidate)
      }
      guard errno == EEXIST else {
        throw AtomicFileWriteError.posix(operation: "open", errno: errno, path: candidate)
      }
    }
    throw AtomicFileWriteError.posix(
      operation: "open", errno: EEXIST, path: url.path(percentEncoded: false))
  }

  /// `write(2)` may return a short count or fail with `EINTR`; a single call plus a length check
  /// would turn both into a spurious, permanent failure.
  private static func writeAll(_ data: Data, to descriptor: CInt, path: String) throws {
    try data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          throw AtomicFileWriteError.posix(operation: "write", errno: errno, path: path)
        }
        // A zero-byte write on a regular file is not progress; looping on it would spin forever.
        guard written > 0 else {
          throw AtomicFileWriteError.posix(operation: "write", errno: EIO, path: path)
        }
        pointer += written
        remaining -= written
      }
    }
  }

  private static func fsyncDirectory(_ url: URL) {
    let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = fsync(descriptor)
  }
}
