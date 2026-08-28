import Darwin
import Foundation

/// A plain POSIX TCP probe: does anything answer on `host:port`?
///
/// Used by exactly one caller — the cold-boot qualification of a managed macOS image, which has to
/// prove the seal-time SSH lockdown survived a reboot (`docs/design/distribution.md`, "Build →
/// qualify → promote", step 3).
///
/// `HostSetup.PortProbe` is the same check, and this is deliberately *not* it: `HostSetup` sits
/// above `Orchestration` in the dependency graph (it talks to a daemon over the socket and must
/// keep working against any daemon), so importing it here would invert that. Moving the shared
/// implementation down into `RunnerCore` was the other option and was rejected: that target is
/// documented as pure domain code with no I/O, and a `socket(2)` call is exactly what it excludes.
/// Forty lines of POSIX is the cheaper duplication.
enum TCPPortProbe {
  /// True when something answers on `host:port` within `timeout` (a listener accepted the
  /// connection, or has not yet refused it); false once the connection is actively refused or
  /// nothing answers before the timeout.
  /// Runs the blocking POSIX probe on a GCD thread: `connect`/`poll` can park a thread for the
  /// whole timeout, and parking a cooperative-pool thread starves every other task in the
  /// process (measured 2026-08-28: the CI runner's 3-thread pool starved the metrics endpoint's
  /// request handling into URLSession timeouts).
  static func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: blockingIsOpen(host: host, port: port, timeout: timeout))
      }
    }
  }

  private static func blockingIsOpen(host: String, port: UInt16, timeout: Duration) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

    let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let timeoutMs = Int32(
      clamping: timeout.components.seconds * 1_000
        + timeout.components.attoseconds / 1_000_000_000_000_000)
    guard poll(&descriptor, 1, timeoutMs) > 0, descriptor.revents & Int16(POLLOUT) != 0 else {
      return false
    }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
    return socketError == 0
  }
}
