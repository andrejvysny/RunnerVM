import Darwin
import Foundation
import Testing

@testable import HostSetup

@Suite struct PortProbeTests {
  @Test func openListenerIsDetected() throws {
    let (fd, port) = try Self.bindListener()
    defer { close(fd) }
    #expect(PortProbe.isOpen(host: "127.0.0.1", port: port, timeout: .milliseconds(500)))
  }

  @Test func closedPortIsNotDetected() throws {
    let (fd, port) = try Self.bindListener()
    close(fd)  // free the port; nothing is listening any more
    #expect(!PortProbe.isOpen(host: "127.0.0.1", port: port, timeout: .milliseconds(300)))
  }

  @Test func nothingEverListenedIsNotDetected() {
    // Port 1 is a well-known privileged port real code never binds; refused on any sane host.
    #expect(!PortProbe.isOpen(host: "127.0.0.1", port: 1, timeout: .milliseconds(300)))
  }

  /// Binds an ephemeral loopback listener and returns its fd (caller closes it) and the port the
  /// kernel assigned. Shared with `SmokeTestTests`, which points the ssh-closed check at one of
  /// these instead of the real port 22.
  static func bindListener() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PortProbeTestError.socketFailed }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
      close(fd)
      throw PortProbeTestError.socketFailed
    }

    let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      close(fd)
      throw PortProbeTestError.bindFailed
    }
    guard listen(fd, 1) == 0 else {
      close(fd)
      throw PortProbeTestError.listenFailed
    }

    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      close(fd)
      throw PortProbeTestError.getsocknameFailed
    }
    return (fd, UInt16(bigEndian: actual.sin_port))
  }
}

enum PortProbeTestError: Error {
  case socketFailed, bindFailed, listenFailed, getsocknameFailed
}
