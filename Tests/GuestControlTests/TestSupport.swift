import Foundation

/// Short root under /tmp: `sockaddr_un.sun_path` holds 104 bytes and a home directory blows it.
struct SocketTree {
  let root: URL

  init() throws {
    root = URL(fileURLWithPath: "/tmp/rvm-guest-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func socket(_ name: String = "agent.sock") -> URL { root.appending(path: name) }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A listening Unix socket that accepts and immediately hangs up — exactly what vmworker's agent
/// bridge does while the guest has booted but has no agent on vsock port 4050 yet.
///
/// `@unchecked Sendable`: `accepted`/`running` are guarded by `lock`, `listenFD` is written once.
final class AcceptAndCloseServer: @unchecked Sendable {
  private let path: String
  private let listenFD: CInt
  private let lock = NSLock()
  private var accepted = 0
  private var running = true

  init(path url: URL) throws {
    path = url.path(percentEncoded: false)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout<sockaddr_un>.size - 2 else { throw POSIXError(.ENAMETOOLONG) }
    unlink(path)
    listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFD >= 0 else { throw POSIXError(.EBADF) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listenFD, 32) == 0 else {
      close(listenFD)
      throw POSIXError(.EADDRINUSE)
    }
    let thread = Thread { [self] in acceptLoop() }
    thread.name = "accept-and-close"
    thread.start()
  }

  private func acceptLoop() {
    while true {
      let descriptor = accept(listenFD, nil, nil)
      guard descriptor >= 0 else {
        lock.lock()
        let keepGoing = running && errno == EINTR
        lock.unlock()
        if keepGoing { continue }
        return
      }
      close(descriptor)
      lock.lock()
      accepted += 1
      lock.unlock()
    }
  }

  var acceptedConnections: Int {
    lock.lock()
    defer { lock.unlock() }
    return accepted
  }

  func stop() {
    lock.lock()
    running = false
    lock.unlock()
    close(listenFD)
    unlink(path)
  }
}
