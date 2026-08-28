import Darwin
import Foundation

public enum DurableFileError: Error, CustomStringConvertible, Equatable {
  case posix(operation: String, errno: Int32, path: String)

  public var description: String {
    switch self {
    case let .posix(operation, code, path):
      "\(operation) failed on \(path): \(String(cString: strerror(code)))"
    }
  }
}

/// Crash-durable replacement of a small file.
///
/// `Data.write(options: .atomic)` renames, which survives a *process* crash but not a power loss:
/// the rename can reach the directory before the file's own contents reach the platter, and the
/// directory entry itself can be lost even after the contents are durable. Anything whose absence
/// silently changes identity -- `machine-identifier.bin` above all, where a lost file makes the
/// next boot mint a *second* virtual Mac against auxiliary storage bound to the first -- needs the
/// full sequence:
///
///     unique temporary (O_EXCL) -> write-all -> fsync(file) -> rename -> fsync(directory)
///
/// Kept here rather than in `RunnerCore` because that module is deliberately I/O-free, and in its
/// own file rather than inside `MacOSMachineIdentity` because the primitive has to be correct
/// independently of its first caller.
public enum DurableFile {
  /// Replaces `url` with `data`, or throws leaving the previous contents untouched.
  ///
  /// - Parameters:
  ///   - mode: Permissions of the *new* file. The temporary is created with them directly, so the
  ///     file is never briefly world-readable.
  public static func atomicReplace(_ data: Data, at url: URL, mode: mode_t = 0o600) throws {
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
      throw DurableFileError.posix(operation: "fsync", errno: errno, path: temporaryPath)
    }
    guard rename(temporaryPath, path) == 0 else {
      throw DurableFileError.posix(operation: "rename", errno: errno, path: path)
    }
    succeeded = true
    // Only after the directory entry is on the platter is the new name guaranteed to survive a
    // power loss. A failure to even open the directory is not fatal to the caller -- the data is
    // durable and the rename has happened -- so this is best effort, exactly like every other
    // fsync-the-parent in the tree.
    fsyncDirectory(directory)
  }

  /// `mkstemp(3)` semantics with a caller-chosen mode: a name no other process can be holding,
  /// created `O_EXCL`, in the destination's own directory so the later `rename(2)` cannot cross a
  /// filesystem boundary.
  ///
  /// The pid is *not* part of the name. A pid repeats after a wrap and says nothing about whether
  /// the previous owner is alive, so a crashed run's leftovers would be adopted by a later one
  /// holding the same pid; a UUID cannot collide with anything.
  private static func createTemporary(besides url: URL, mode: mode_t) throws -> (CInt, String) {
    let directory = url.deletingLastPathComponent()
    for _ in 0..<8 {
      let name = "\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))"
      let candidate = directory.appendingPathComponent(name).path(percentEncoded: false)
      let descriptor = open(candidate, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
      if descriptor >= 0 {
        // `open(2)` applies the process umask to `mode`; the identity file has to be 0600 whatever
        // the daemon's umask happens to be.
        guard fchmod(descriptor, mode) == 0 else {
          let failure = errno
          close(descriptor)
          unlink(candidate)
          throw DurableFileError.posix(operation: "fchmod", errno: failure, path: candidate)
        }
        return (descriptor, candidate)
      }
      guard errno == EEXIST else {
        throw DurableFileError.posix(operation: "open", errno: errno, path: candidate)
      }
    }
    throw DurableFileError.posix(
      operation: "open", errno: EEXIST, path: url.path(percentEncoded: false))
  }

  /// `write(2)` may return a short count or fail with `EINTR`; a single call plus a length check
  /// would turn both into a spurious, permanent failure of the caller.
  private static func writeAll(_ data: Data, to descriptor: CInt, path: String) throws {
    try data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          throw DurableFileError.posix(operation: "write", errno: errno, path: path)
        }
        // A zero-byte write on a regular file is not progress; looping on it would spin forever.
        guard written > 0 else {
          throw DurableFileError.posix(operation: "write", errno: EIO, path: path)
        }
        pointer += written
        remaining -= written
      }
    }
  }

  /// Flushes a directory's entries. Best effort by design: the caller has already made the file
  /// contents durable, and a directory that cannot be opened is not a reason to fail a write that
  /// succeeded.
  public static func fsyncDirectory(_ url: URL) {
    let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = fsync(descriptor)
  }
}
