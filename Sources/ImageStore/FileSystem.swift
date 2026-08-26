import Darwin
import Foundation

/// Thin POSIX layer used by both stores. Everything here is synchronous and non-recursive except
/// where noted; the actors above serialize access.
enum FileSystem {
  static func posixError(_ code: Int32, _ operation: String, _ path: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
      NSLocalizedDescriptionKey: "\(operation) failed on \(path): \(String(cString: strerror(code)))",
    ])
  }

  static func ensureDirectory(_ url: URL, permissions: mode_t = 0o755) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: permissions)]
    )
  }

  static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  static func isDirectory(_ url: URL) -> Bool {
    var flag: ObjCBool = false
    let found = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &flag)
    return found && flag.boolValue
  }

  static func fileSize(at url: URL) throws -> UInt64 {
    let info = try fileInfo(url)
    return info.st_size < 0 ? 0 : UInt64(info.st_size)
  }

  /// Blocks actually committed, which is what a sparse raw disk or an APFS clone really costs.
  /// `st_blocks` is always in 512-byte units regardless of the filesystem block size.
  static func allocatedBytes(at url: URL) -> UInt64 {
    guard let info = try? fileInfo(url) else { return 0 }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { return UInt64(info.st_blocks) * 512 }
    var total = UInt64(info.st_blocks) * 512
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
      return total
    }
    for case let child as URL in walker {
      if let childInfo = try? fileInfo(child) { total += UInt64(childInfo.st_blocks) * 512 }
    }
    return total
  }

  static func fileInfo(_ url: URL) throws -> Darwin.stat {
    let path = url.path(percentEncoded: false)
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { throw posixError(errno, "stat", path) }
    return info
  }

  static func modificationDate(at url: URL) throws -> Date {
    let info = try fileInfo(url)
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
  }

  static func setMode(_ mode: mode_t, at url: URL) throws {
    let path = url.path(percentEncoded: false)
    guard chmod(path, mode) == 0 else { throw posixError(errno, "chmod", path) }
  }

  /// Published images are read-only so a bug cannot mutate a blob another instance is cloned from.
  static func makeReadOnlyTree(_ url: URL, fileMode: mode_t = 0o444, directoryMode: mode_t = 0o555) throws {
    try walk(url) { child, isDirectory in
      try setMode(isDirectory ? directoryMode : fileMode, at: child)
    }
  }

  /// Unlinking a child needs write permission on its *directory*, so deletion has to undo
  /// `makeReadOnlyTree` before `removeItem` can succeed.
  static func makeWritableTree(_ url: URL) throws {
    try walk(url) { child, isDirectory in
      try setMode(isDirectory ? 0o755 : 0o644, at: child)
    }
  }

  private static func walk(_ url: URL, _ body: (URL, Bool) throws -> Void) throws {
    guard exists(url) else { return }
    var children: [URL] = []
    if isDirectory(url),
       let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
      for case let child as URL in walker { children.append(child) }
    }
    // Deepest first: a directory must stay traversable while its children are being adjusted.
    for child in children.reversed() { try body(child, isDirectory(child)) }
    try body(url, isDirectory(url))
  }

  static func removeIfPresent(_ url: URL) throws {
    guard exists(url) else { return }
    try makeWritableTree(url)
    try FileManager.default.removeItem(at: url)
  }

  /// `rename(2)` rather than `FileManager.moveItem`, because only the syscall guarantees that a
  /// crash leaves either the old or the new name — never a half-populated destination (spec §120).
  static func atomicRename(from source: URL, to destination: URL) throws {
    let src = source.path(percentEncoded: false)
    let dst = destination.path(percentEncoded: false)
    guard rename(src, dst) == 0 else { throw posixError(errno, "rename", dst) }
  }

  /// Flushes directory entries so a published name survives a power loss (spec §120).
  static func fsyncDirectory(_ url: URL) {
    let fd = open(url.path(percentEncoded: false), O_RDONLY)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = fsync(fd)
  }

  static func truncate(_ url: URL, to bytes: UInt64) throws {
    let path = url.path(percentEncoded: false)
    guard Darwin.truncate(path, off_t(bytes)) == 0 else { throw posixError(errno, "truncate", path) }
  }

  static func createEmptyFile(at url: URL, mode: mode_t) throws {
    let path = url.path(percentEncoded: false)
    let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, mode)
    guard fd >= 0 else { throw posixError(errno, "open", path) }
    close(fd)
  }

  static func write(_ data: Data, to url: URL, mode: mode_t) throws {
    try data.write(to: url, options: .atomic)
    try setMode(mode, at: url)
  }

  static func read(_ url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  /// Deletes `.tmp` children older than `retention`. A crash leaves an identifiable temporary object
  /// rather than a half-valid final one (spec §120); this is what eventually reclaims it.
  static func sweepStaleDirectories(in root: URL, olderThan retention: Duration, now: Date) throws -> [URL] {
    guard exists(root) else { return [] }
    let cutoff = now.addingTimeInterval(-seconds(retention))
    var removed: [URL] = []
    for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard let modified = try? modificationDate(at: child), modified < cutoff else { continue }
      try removeIfPresent(child)
      removed.append(child)
    }
    return removed
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
