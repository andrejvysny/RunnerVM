import Foundation
import RunnerCore

/// `logs/builds/<id>/build.log`: the append-only transcript `build.log` (RPC) pages through.
///
/// An actor rather than a plain handle: the exec pump writes from a child task while `readLog`
/// answers RPCs from the daemon socket, and the file offset is the one thing both share.
///
/// The cap is enforced on the way in, not by truncation afterwards: a runaway step must fail the
/// build (`BUILD_STEP_OUTPUT_TOO_LARGE`) rather than silently lose the beginning of its own output.
public actor BuildLogWriter {
  private let url: URL
  private let maxBytes: UInt64
  private var handle: FileHandle?
  private var written: UInt64 = 0
  private var sinceSync: UInt64 = 0

  /// Bytes between `fsync`s. The log is diagnostics, not state, so a crash may lose the tail; this
  /// only bounds how much.
  private static let syncEvery: UInt64 = 256 * 1_024

  public init(url: URL, maxBytes: UInt64) throws {
    self.url = url
    self.maxBytes = maxBytes
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: url.path(percentEncoded: false), contents: nil,
      attributes: [.posixPermissions: 0o600])
    handle = try FileHandle(forWritingTo: url)
    try handle?.seekToEnd()
  }

  /// `true` while the cap still has room; `false` once this write would exceed it.
  @discardableResult
  public func write(_ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    guard written + UInt64(data.count) <= maxBytes else { return false }
    try? handle?.write(contentsOf: data)
    written += UInt64(data.count)
    sinceSync += UInt64(data.count)
    if sinceSync >= Self.syncEvery {
      sinceSync = 0
      try? handle?.synchronize()
    }
    return true
  }

  @discardableResult
  public func line(_ text: String) -> Bool {
    write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
  }

  public func close() {
    try? handle?.synchronize()
    try? handle?.close()
    handle = nil
  }

  public var byteCount: UInt64 { written }

  /// Paged read for `build.log`. A missing file reads as empty: the log directory is created with
  /// the build row, but a build that failed in `start` never wrote a byte.
  public static func read(url: URL, offset: Int64, maxBytes: Int64) -> (data: Data, next: Int64) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), offset) }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil else { return (Data(), offset) }
    let data = (try? handle.read(upToCount: Int(max(0, maxBytes)))) ?? Data()
    return (data, max(0, offset) + Int64(data.count))
  }
}
