import Foundation

/// Minimal blocking accept loop for a Unix-domain socket.
///
/// A near-twin of `RPC.UnixSocketListener`, duplicated on purpose: VirtualizationCore does not
/// depend on the RPC target (Package.swift), and the agent bridge carries opaque bytes rather than
/// RPC frames, so it needs the raw descriptor and nothing else.
///
/// `@unchecked Sendable`: `wakeWrite` and `shutdownRequested` are guarded by `lock`; the remaining
/// descriptors are written once in `init` and then touched only by the accept thread.
final class UnixSocketAcceptor: @unchecked Sendable {
  private let path: String
  private let listenFD: CInt
  private let wakeRead: CInt
  private var wakeWrite: CInt
  private let lock = NSLock()
  private var shutdownRequested = false

  /// Binds `<path>.tmp` at mode 0600 and renames it over `path`, so a peer never sees a socket
  /// that is listening but still world-accessible.
  init(path url: URL, backlog: Int32 = 16) throws {
    let finalPath = url.path
    let stagingPath = finalPath + ".tmp"
    guard stagingPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
      throw VsockBridgeError.socketPathTooLong(stagingPath)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw VsockBridgeError.posix(operation: "socket", errno: errno) }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    do {
      try Self.publish(descriptor: descriptor, staging: stagingPath, final: finalPath, backlog: backlog)
    } catch {
      close(descriptor)
      unlink(stagingPath)
      throw error
    }
    var pipeFDs: [CInt] = [-1, -1]
    guard pipeFDs.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
      close(descriptor)
      unlink(finalPath)
      throw VsockBridgeError.posix(operation: "pipe", errno: errno)
    }
    for fd in pipeFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    self.path = finalPath
    self.listenFD = descriptor
    self.wakeRead = pipeFDs[0]
    self.wakeWrite = pipeFDs[1]
  }

  private static func publish(descriptor: CInt, staging: String, final: String, backlog: Int32) throws {
    unlink(staging)
    try bind(descriptor: descriptor, to: staging)
    guard chmod(staging, 0o600) == 0 else {
      throw VsockBridgeError.posix(operation: "chmod", errno: errno)
    }
    guard listen(descriptor, backlog) == 0 else {
      throw VsockBridgeError.posix(operation: "listen", errno: errno)
    }
    guard rename(staging, final) == 0 else {
      throw VsockBridgeError.posix(operation: "rename", errno: errno)
    }
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw VsockBridgeError.posix(operation: "fcntl", errno: errno)
    }
  }

  private static func bind(descriptor: CInt, to path: String) throws {
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
        Foundation.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw VsockBridgeError.posix(operation: "bind", errno: errno) }
  }

  /// Blocks until ``shutdown()``. Run on a dedicated thread. Unlinks the socket on exit.
  func run(onAccept: @Sendable (CInt, uid_t) -> Void) {
    var descriptors = [
      pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
      pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
    ]
    loop: while true {
      let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress!, 2, -1) }
      if ready < 0 {
        if errno == EINTR { continue }
        break
      }
      if descriptors[1].revents != 0 { break }
      guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
      while true {
        let accepted = accept(listenFD, nil, nil)
        if accepted < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          break loop
        }
        _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)
        // BSD accept(2) hands down the listener's O_NONBLOCK; the relay wants blocking reads.
        let flags = fcntl(accepted, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(accepted, F_SETFL, flags & ~O_NONBLOCK) }
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(accepted, &uid, &gid) == 0 else {
          close(accepted)
          continue
        }
        onAccept(accepted, uid)
      }
    }
    close(listenFD)
    close(wakeRead)
    unlink(path)
  }

  func shutdown() {
    lock.lock()
    defer { lock.unlock() }
    guard !shutdownRequested else { return }
    shutdownRequested = true
    var byte: UInt8 = 1
    _ = withUnsafeBytes(of: &byte) { write(wakeWrite, $0.baseAddress!, 1) }
    close(wakeWrite)
    wakeWrite = -1
  }
}
