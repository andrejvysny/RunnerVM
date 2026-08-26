import Foundation

public enum VsockBridgeError: Error, CustomStringConvertible, Equatable {
  case socketPathTooLong(String)
  case posix(operation: String, errno: Int32)
  case alreadyStarted

  public var description: String {
    switch self {
    case .socketPathTooLong(let path): "unix socket path too long: \(path)"
    case .posix(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
    case .alreadyStarted: "bridge already started"
    }
  }
}

/// Raw UDS ⇄ vsock bridge in front of the guest agent (Proto/worker_protocol.md).
///
/// Each accepted connection on `<socket-dir>/vm-<shortid>-agent.sock` gets its own fresh
/// connection to the guest port; the two halves are relayed byte for byte and close together. A
/// connection that arrives before the guest listens is closed immediately rather than parked, so
/// callers get a fast, unambiguous failure instead of a hang.
@MainActor
public final class VsockBridge {
  /// Opens one connection to the guest and yields an owned descriptor. Injected so the accept and
  /// relay paths can be tested without the virtualization entitlement.
  public typealias GuestConnector = @Sendable () async throws -> CInt

  public let socketPath: URL
  private let allowedUID: uid_t
  private let connect: GuestConnector
  private let registry = RelayRegistry()
  private var acceptor: UnixSocketAcceptor?
  private var acceptThread: Thread?

  public init(socketPath: URL, allowedUID: uid_t = getuid(), connect: @escaping GuestConnector) {
    self.socketPath = socketPath
    self.allowedUID = allowedUID
    self.connect = connect
  }

  /// Number of client connections currently relayed. Safe to read from any isolation domain.
  public nonisolated var activeConnections: Int { registry.count }

  /// Test hook: invoked off the main actor whenever ``activeConnections`` changes. Set before
  /// ``start()``.
  public nonisolated func onConnectionCountChanged(_ body: (@Sendable (Int) -> Void)?) {
    registry.onChange(body)
  }

  public func start() throws {
    guard acceptor == nil else { throw VsockBridgeError.alreadyStarted }
    let acceptor = try UnixSocketAcceptor(path: socketPath)
    self.acceptor = acceptor
    let allowedUID = self.allowedUID
    let connect = self.connect
    let registry = self.registry
    let thread = Thread {
      acceptor.run { descriptor, uid in
        guard uid == allowedUID else {
          close(descriptor)
          return
        }
        registry.enter(descriptor)
        Task.detached { await VsockBridge.attach(descriptor, connect: connect, registry: registry) }
      }
    }
    thread.name = "rvm-bridge-accept"
    self.acceptThread = thread
    thread.start()
  }

  public func stop() {
    acceptor?.shutdown()
    acceptor = nil
    registry.closeAll()
  }

  private nonisolated static func attach(
    _ descriptor: CInt, connect: GuestConnector, registry: RelayRegistry
  ) async {
    do {
      let guestFD = try await connect()
      let relay = SocketRelay(client: descriptor, guest: guestFD) { registry.leave(descriptor) }
      registry.track(relay, for: descriptor)
      relay.start()
    } catch {
      close(descriptor)
      registry.leave(descriptor)
    }
  }
}

/// Live relays keyed by client descriptor, plus the connection counter the worker reports over
/// `agent.bridgeStatus`. Touched from the accept thread, relay threads and the main actor.
final class RelayRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var relays: [CInt: SocketRelay] = [:]
  private var pending: Set<CInt> = []
  private var observer: (@Sendable (Int) -> Void)?

  var count: Int { lock.withLock { relays.count + pending.count } }

  func onChange(_ body: (@Sendable (Int) -> Void)?) {
    lock.withLock { observer = body }
  }

  /// Counted from accept time, so a connection still dialling the guest already reads as active.
  func enter(_ descriptor: CInt) {
    notify(lock.withLock {
      pending.insert(descriptor)
      return relays.count + pending.count
    })
  }

  func track(_ relay: SocketRelay, for descriptor: CInt) {
    lock.withLock {
      pending.remove(descriptor)
      relays[descriptor] = relay
    }
  }

  func leave(_ descriptor: CInt) {
    notify(lock.withLock {
      relays[descriptor] = nil
      pending.remove(descriptor)
      return relays.count + pending.count
    })
  }

  func closeAll() {
    let live = lock.withLock { Array(relays.values) }
    for relay in live { relay.forceClose() }
  }

  private func notify(_ count: Int) {
    let observer = lock.withLock { self.observer }
    observer?(count)
  }
}
