import Foundation

/// One-shot broadcast signal. Tests wait on real events instead of sleeping.
actor Signal {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fire() {
    guard !fired else { return }
    fired = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    guard !fired else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

/// Counts arrivals so a test can wait for the n-th one.
actor Latch {
  private var count = 0
  private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func signal() {
    count += 1
    let ready = waiters.filter { $0.target <= count }
    waiters.removeAll { $0.target <= count }
    for waiter in ready { waiter.continuation.resume() }
  }

  func wait(for target: Int) async {
    guard count < target else { return }
    await withCheckedContinuation { waiters.append((target, $0)) }
  }
}

/// Suspends until the surrounding task is cancelled, without polling.
actor CancellationGate {
  private var continuation: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  func wait() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if cancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          self.continuation = continuation
        }
      }
    } onCancel: {
      Task { await self.trip() }
    }
  }

  private func trip() {
    cancelled = true
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}

/// Short path under /tmp: `sockaddr_un.sun_path` only holds 104 bytes and the per-user temporary
/// directory is close to that on macOS.
func makeSocketPath() throws -> URL {
  let directory = URL(
    fileURLWithPath: "/tmp/rvm-rpc-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("rpc.sock")
}

func removeSocketDirectory(_ path: URL) {
  try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
}

enum RawSocket {
  static func connect(to path: URL, receiveTimeout: Int32 = 5) throws -> CInt {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ECONNREFUSED) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(descriptor)
      throw POSIXError(.ECONNREFUSED)
    }
    var timeout = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return descriptor
  }

  static func write(_ descriptor: CInt, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress!, $0.count) }
  }

  /// True when the peer closed the connection rather than answering.
  static func readsEOF(_ descriptor: CInt) -> Bool {
    var scratch = [UInt8](repeating: 0, count: 64)
    return scratch.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) } == 0
  }
}
