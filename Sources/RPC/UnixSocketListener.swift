import Foundation

struct AcceptedConnection: Sendable, Hashable {
  let descriptor: CInt
  let uid: uid_t
  let gid: gid_t
}

/// Owns the listening Unix-domain socket and runs a blocking accept loop on a dedicated thread.
///
/// NIO's `ServerBootstrap` never surfaces the accepted file descriptor, and `getpeereid(2)` needs
/// it, so the accept side is hand-rolled and each accepted descriptor is handed to
/// `ClientBootstrap.withConnectedSocket(_:)`.
///
/// `@unchecked Sendable`: `wakeWrite` and `shutdownRequested` are guarded by `lock`; `listenFD` and
/// `wakeRead` are written once in `init` and only touched by the accept thread afterwards.
final class UnixSocketListener: @unchecked Sendable {
  private let path: String
  private let listenFD: CInt
  private let wakeRead: CInt
  private var wakeWrite: CInt
  private let lock = NSLock()
  private var shutdownRequested = false

  /// Binds `<path>.tmp` with mode 0600 and renames it over `path`, so a peer never observes a
  /// socket that is listening but still group/world accessible.
  init(path url: URL, backlog: Int32 = 64) throws {
    let finalPath = url.path
    let stagingPath = finalPath + ".tmp"
    let maxLength = MemoryLayout<sockaddr_un>.size - MemoryLayout<UInt8>.size * 2
    guard stagingPath.utf8.count < maxLength else {
      throw RPCServerError.socketPathTooLong(stagingPath)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RPCServerError.posix(operation: "socket", errno: errno) }
    // runnerd posix_spawns vmworkers; listening/accepted sockets must never leak into them.
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    do {
      unlink(stagingPath)
      try UnixSocketListener.bind(descriptor: descriptor, to: stagingPath)
      guard chmod(stagingPath, 0o600) == 0 else {
        throw RPCServerError.posix(operation: "chmod", errno: errno)
      }
      guard listen(descriptor, backlog) == 0 else {
        throw RPCServerError.posix(operation: "listen", errno: errno)
      }
      guard rename(stagingPath, finalPath) == 0 else {
        throw RPCServerError.posix(operation: "rename", errno: errno)
      }
      let flags = fcntl(descriptor, F_GETFL, 0)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw RPCServerError.posix(operation: "fcntl", errno: errno)
      }
    } catch {
      close(descriptor)
      unlink(stagingPath)
      throw error
    }
    var pipeFDs: [CInt] = [-1, -1]
    guard pipeFDs.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
      close(descriptor)
      unlink(finalPath)
      throw RPCServerError.posix(operation: "pipe", errno: errno)
    }
    for fd in pipeFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    self.path = finalPath
    self.listenFD = descriptor
    self.wakeRead = pipeFDs[0]
    self.wakeWrite = pipeFDs[1]
  }

  private static func bind(descriptor: CInt, to path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: pathBytes)
      raw[pathBytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Foundation.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw RPCServerError.posix(operation: "bind", errno: errno) }
  }

  /// Blocks until ``shutdown()`` is called. Run this on a dedicated thread.
  func run(onAccept: @Sendable (AcceptedConnection) -> Void) {
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
        guard let connection = UnixSocketListener.peerCredentials(of: accepted) else {
          close(accepted)
          continue
        }
        onAccept(connection)
      }
    }
    close(listenFD)
    close(wakeRead)
    unlink(path)
  }

  private static func peerCredentials(of descriptor: CInt) -> AcceptedConnection? {
    var uid = uid_t()
    var gid = gid_t()
    guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
    return AcceptedConnection(descriptor: descriptor, uid: uid, gid: gid)
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
