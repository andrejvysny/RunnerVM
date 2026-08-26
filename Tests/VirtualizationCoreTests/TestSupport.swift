import Foundation

/// Short-lived scratch directory under `/tmp`.
///
/// `FileManager.temporaryDirectory` points at `/var/folders/…`, which alone eats most of the
/// 104-byte `sun_path` budget, so socket tests would fail for the wrong reason.
enum Scratch {
  static func makeDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/rvm-t-\(label)-\(UInt32.random(in: 0...0xFFFF_FFFF))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

/// Runs blocking socket I/O off the cooperative pool and hands the result back to the test.
func onBackgroundThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
  await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
    let thread = Thread { continuation.resume(returning: body()) }
    thread.stackSize = 256 << 10
    thread.start()
  }
}

enum UnixSocket {
  static func connect(to path: String) -> CInt {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(descriptor)
      return -1
    }
    return descriptor
  }

  static func send(_ descriptor: CInt, _ text: String) -> Bool {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes {
        write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      guard written > 0 else { return false }
      offset += written
    }
    return true
  }

  /// Reads exactly `count` bytes, or returns nil on EOF/error.
  static func receive(_ descriptor: CInt, count: Int) -> String? {
    var buffer = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let read = buffer.withUnsafeMutableBytes {
        Foundation.read(descriptor, $0.baseAddress!.advanced(by: filled), count - filled)
      }
      guard read > 0 else { return nil }
      filled += read
    }
    return String(decoding: buffer, as: UTF8.self)
  }

  static func isAtEOF(_ descriptor: CInt) -> Bool {
    var byte: UInt8 = 0
    return withUnsafeMutablePointer(to: &byte) { read(descriptor, $0, 1) == 0 }
  }
}

/// Lets a test await a specific connection count without polling or sleeping.
final class CountWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var latest = 0
  private var waiting: (target: Int, continuation: CheckedContinuation<Void, Never>)?

  func record(_ count: Int) {
    var resume: CheckedContinuation<Void, Never>?
    lock.lock()
    latest = count
    if let waiting, waiting.target == count {
      resume = waiting.continuation
      self.waiting = nil
    }
    lock.unlock()
    resume?.resume()
  }

  func wait(for target: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if latest == target {
        lock.unlock()
        continuation.resume()
        return
      }
      waiting = (target, continuation)
      lock.unlock()
    }
  }
}
