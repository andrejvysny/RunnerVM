import Foundation

/// Copies bytes both ways between two connected stream sockets until both directions are done,
/// then closes both descriptors exactly once and reports completion.
///
/// One thread per direction with blocking reads: the agent bridge carries a handful of long-lived
/// control connections, so an event loop would buy nothing, and `shutdown(2)` is enough to unblock
/// a stuck peer during teardown.
///
/// `@unchecked Sendable`: `remaining` is guarded by `lock`; the descriptors are immutable and each
/// is read by exactly one thread until the final close.
final class SocketRelay: @unchecked Sendable {
  private let client: CInt
  private let guest: CInt
  private let onFinish: @Sendable () -> Void
  private let lock = NSLock()
  private var remaining = 2

  init(client: CInt, guest: CInt, onFinish: @escaping @Sendable () -> Void) {
    self.client = client
    self.guest = guest
    self.onFinish = onFinish
    // A peer that vanishes mid-write must surface as EPIPE, not as a signal that kills the worker.
    for descriptor in [client, guest] {
      var on: CInt = 1
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<CInt>.size))
      let flags = fcntl(descriptor, F_GETFL, 0)
      if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
    }
  }

  func start() {
    spawn(name: "rvm-bridge-c2g") { self.pump(from: self.client, to: self.guest) }
    spawn(name: "rvm-bridge-g2c") { self.pump(from: self.guest, to: self.client) }
  }

  /// Forces both directions to unwind; used when the bridge shuts down while peers are idle.
  func forceClose() {
    shutdown(client, SHUT_RDWR)
    shutdown(guest, SHUT_RDWR)
  }

  private func spawn(name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.stackSize = 128 << 10
    thread.start()
  }

  private func pump(from source: CInt, to sink: CInt) {
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress!, $0.count) }
      if count > 0 {
        guard writeAll(sink, buffer, count) else {
          forceClose()
          break
        }
        continue
      }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        waitReadable(source)
        continue
      }
      if count < 0 {
        forceClose()
        break
      }
      // Clean EOF: pass the half-close on so the peer's own pump unwinds.
      shutdown(source, SHUT_RD)
      shutdown(sink, SHUT_WR)
      break
    }
    finish()
  }

  /// Defensive: the descriptors are put back into blocking mode, but a non-blocking one must wait
  /// rather than spin.
  private func waitReadable(_ descriptor: CInt) {
    var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
    _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress!, 1, 1000) }
  }

  private func writeAll(_ descriptor: CInt, _ bytes: [UInt8], _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
      let written = bytes.withUnsafeBytes {
        write(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
      }
      if written > 0 {
        offset += written
        continue
      }
      if written < 0 && errno == EINTR { continue }
      return false
    }
    return true
  }

  private func finish() {
    lock.lock()
    remaining -= 1
    let last = remaining == 0
    lock.unlock()
    guard last else { return }
    close(client)
    close(guest)
    onFinish()
  }
}
