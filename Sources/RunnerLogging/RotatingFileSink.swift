import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Append-only line sink with in-process size rotation, usable directly as a
/// ``JSONLogHandler`` sink (spec §42).
///
/// Two properties matter more than throughput here. First, rotation happens *in* the writing
/// process, so a rotated file stops growing immediately instead of at the next daemon restart —
/// the limitation `packaging/newsyslog/runnervm.conf` used to document. Second, a logging failure
/// is never allowed to reach the caller: an unwritable file drops the line and bumps a counter
/// that surfaces as `runnervm_log_lines_dropped_total`, because a daemon that dies when its disk
/// fills is strictly worse than one that loses log lines.
///
/// `SIGHUP` reopens the path, so external rename-based rotation (`newsyslog`) still works.
public final class RotatingFileSink: @unchecked Sendable {
  public struct Options: Sendable, Hashable {
    /// Size at which the live file is renamed to `.1`. Checked after each line, so a file can
    /// exceed it by at most one line.
    public var maxSizeBytes: UInt64
    /// How many rotated archives (`.1` … `.maxFiles`) are kept. The live file is extra.
    public var maxFiles: Int
    /// Creation mode of the log file. 0640: readable by the service group, never world-readable.
    public var mode: mode_t

    public init(
      maxSizeBytes: UInt64 = RotatingFileSink.defaultMaxSizeBytes,
      maxFiles: Int = RotatingFileSink.defaultMaxFiles,
      mode: mode_t = 0o640
    ) {
      self.maxSizeBytes = maxSizeBytes
      self.maxFiles = maxFiles
      self.mode = mode
    }
  }

  public static let defaultMaxSizeBytes: UInt64 = 32 << 20
  public static let defaultMaxFiles = 10

  /// Process-wide drop total. A counter on the instance is not enough: the metric is published by
  /// the daemon's maintenance loop, which has no reference to the sinks `runnerd`'s `main` built.
  private static let dropTotal = DropCounter()

  public static var totalDroppedLines: UInt64 { dropTotal.value }

  public nonisolated let url: URL

  private let options: Options
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var currentSize: UInt64 = 0
  private var droppedLineCount: UInt64 = 0
  private var hangupSource: (any DispatchSourceSignal)?
  private var closed = false

  /// Throws only when the file cannot be opened at all, so a caller can fall back to stderr and
  /// say why. Every later failure is absorbed and counted.
  public init(url: URL, options: Options = Options(), reopenOnHangup: Bool = true) throws {
    self.url = url
    self.options = options
    lock.lock()
    let opened = ensureOpenLocked()
    lock.unlock()
    guard opened else {
      throw LogSinkError.cannotOpen(path: url.path(percentEncoded: false), errno: errno)
    }
    if reopenOnHangup { installHangupHandler() }
  }

  deinit {
    hangupSource?.cancel()
    lock.lock()
    closeDescriptorLocked(sync: true)
    lock.unlock()
  }

  /// Lines dropped by *this* sink. `RotatingFileSink.totalDroppedLines` is the process total.
  public var droppedLines: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return droppedLineCount
  }

  public var currentFileSize: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return currentSize
  }

  /// The closure form `LoggingSystemBootstrap.bootstrapJSON(sink:)` and ``LifecycleEventLog`` take.
  public func sink() -> @Sendable (String) -> Void {
    { [self] line in write(line) }
  }

  public func write(_ line: String) {
    var bytes = Array(line.utf8)
    bytes.append(UInt8(ascii: "\n"))
    lock.lock()
    defer { lock.unlock() }
    guard !closed, ensureOpenLocked(), writeAllLocked(bytes) else {
      dropLocked()
      return
    }
    currentSize += UInt64(bytes.count)
    if currentSize >= options.maxSizeBytes { rotateLocked() }
  }

  /// Drops the descriptor and opens the path again. Called on `SIGHUP` and by tests.
  public func reopen() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closeDescriptorLocked(sync: true)
    _ = ensureOpenLocked()
  }

  /// Terminal. Later writes are counted as drops rather than resurrecting the file.
  public func close() {
    hangupSource?.cancel()
    hangupSource = nil
    lock.lock()
    defer { lock.unlock() }
    closed = true
    closeDescriptorLocked(sync: true)
  }

  // MARK: - File handling

  private func ensureOpenLocked() -> Bool {
    if descriptor >= 0 { return true }
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
    let path = url.path(percentEncoded: false)
    let fd = path.withCString {
      Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, options.mode)
    }
    guard fd >= 0 else { return false }
    descriptor = fd
    currentSize = UInt64(max(0, lseek(fd, 0, SEEK_END)))
    return true
  }

  private func closeDescriptorLocked(sync: Bool) {
    guard descriptor >= 0 else { return }
    if sync { _ = fsync(descriptor) }
    _ = Darwin.close(descriptor)
    descriptor = -1
    currentSize = 0
  }

  private func writeAllLocked(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    return bytes.withUnsafeBytes { buffer in
      while offset < buffer.count {
        let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written > 0 {
          offset += written
          continue
        }
        if written < 0, errno == EINTR { continue }
        return false
      }
      return true
    }
  }

  /// fsync only here: a per-line fsync would turn every log statement into a disk round trip, and
  /// the rotation boundary is the only point where losing the tail actually costs a whole file.
  private func rotateLocked() {
    closeDescriptorLocked(sync: true)
    let manager = FileManager.default
    guard options.maxFiles > 0 else {
      try? manager.removeItem(at: url)
      _ = ensureOpenLocked()
      return
    }
    try? manager.removeItem(at: rotatedURL(options.maxFiles))
    for index in stride(from: options.maxFiles - 1, through: 1, by: -1) {
      let source = rotatedURL(index)
      guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
      try? manager.removeItem(at: rotatedURL(index + 1))
      try? manager.moveItem(at: source, to: rotatedURL(index + 1))
    }
    try? manager.removeItem(at: rotatedURL(1))
    try? manager.moveItem(at: url, to: rotatedURL(1))
    _ = ensureOpenLocked()
  }

  public func rotatedURL(_ index: Int) -> URL {
    url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(index)")
  }

  private func dropLocked() {
    droppedLineCount &+= 1
    Self.dropTotal.increment()
  }

  /// `DispatchSource` only observes a signal whose disposition ignores it, so `SIG_IGN` comes
  /// first. Several sinks may install their own source; dispatch signal sources are additive.
  private func installHangupHandler() {
    signal(SIGHUP, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: Self.hangupQueue)
    source.setEventHandler { [weak self] in self?.reopen() }
    source.resume()
    hangupSource = source
  }

  private static let hangupQueue = DispatchQueue(label: "com.runnervm.logging.sighup")
}

public enum LogSinkError: Error, Sendable, CustomStringConvertible {
  case cannotOpen(path: String, errno: Int32)

  public var description: String {
    switch self {
    case let .cannotOpen(path, code):
      "cannot open log file \(path): \(String(cString: strerror(code)))"
    }
  }
}

/// Lock-protected `UInt64`; `Atomic` is not available without importing Synchronization, which
/// would raise this target's platform floor for one counter.
private final class DropCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count: UInt64 = 0

  func increment() {
    lock.lock()
    count &+= 1
    lock.unlock()
  }

  var value: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
