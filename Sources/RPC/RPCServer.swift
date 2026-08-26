import Foundation
import NIOCore
import NIOPosix

/// Length-prefixed JSON RPC server on a Unix-domain socket.
public actor RPCServer {
  private let protocolName: RPCProtocol
  private let socketPath: URL
  private let allowedUIDs: Set<uid_t>?
  private let limits: ConnectionLimits
  private var handlers: [String: MethodHandler] = [:]
  private var listener: UnixSocketListener?
  private var acceptTask: Task<Void, Never>?
  private var acceptContinuation: AsyncStream<AcceptedConnection>.Continuation?
  private var openConnections: [ObjectIdentifier: OpenConnection] = [:]

  public init(
    protocol protocolName: RPCProtocol,
    socketPath: URL,
    allowedUIDs: Set<uid_t>? = nil,
    limits: ConnectionLimits = ConnectionLimits()
  ) {
    self.protocolName = protocolName
    self.socketPath = socketPath
    self.allowedUIDs = allowedUIDs
    self.limits = limits
  }

  /// Register every method before ``start()``: each accepted connection captures the catalogue as
  /// it stands when the connection is served.
  public func register(
    method: String,
    class methodClass: MethodClass,
    handler: @escaping @Sendable (Envelope, RequestContext) async throws -> JSONValue
  ) {
    handlers[method] = .unary(methodClass, handler)
  }

  public func registerStream(
    method: String,
    class methodClass: MethodClass = .readOnly,
    handler: @escaping @Sendable (Envelope, RequestContext, StreamSink) async throws -> Void
  ) {
    handlers[method] = .stream(methodClass, handler)
  }

  /// Binds and publishes the socket, then serves accepted connections in the background.
  public func start() async throws {
    guard listener == nil else { throw RPCServerError.alreadyStarted }
    let listener = try UnixSocketListener(path: socketPath)
    let (stream, continuation) = AsyncStream<AcceptedConnection>.makeStream(
      bufferingPolicy: .unbounded)
    self.listener = listener
    self.acceptContinuation = continuation
    let thread = Thread {
      listener.run { continuation.yield($0) }
      continuation.finish()
    }
    thread.name = "runnervm-rpc-accept"
    thread.start()
    acceptTask = Task { [weak self] in
      for await accepted in stream {
        await self?.dispatch(accepted)
      }
    }
  }

  public func stop() async {
    listener?.shutdown()
    listener = nil
    acceptContinuation?.finish()
    acceptContinuation = nil
    for connection in openConnections.values {
      connection.channel.close(promise: nil)
    }
    openConnections.removeAll()
    acceptTask?.cancel()
    acceptTask = nil
  }

  private func dispatch(_ accepted: AcceptedConnection) {
    guard allowedUIDs.map({ $0.contains(accepted.uid) }) ?? true else {
      close(accepted.descriptor)
      return
    }
    Task { await self.serve(accepted) }
  }

  private func serve(_ accepted: AcceptedConnection) async {
    let cap = protocolName.frameCap
    let idle = limits.idleTimeAmount
    do {
      let asyncChannel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .withConnectedSocket(accepted.descriptor) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers([
              IdleStateHandler(readTimeout: idle),
              IdleCloseHandler(),
              ByteToMessageHandler(FrameDecoder(maxFrameLength: cap)),
              MessageToByteHandler(FrameEncoder(maxFrameLength: cap)),
            ])
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
          }
        }
      try await run(asyncChannel, peerUID: accepted.uid)
    } catch {
      // A framing violation or peer reset ends this connection only.
    }
  }

  private func run(
    _ asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, peerUID: uid_t
  ) async throws {
    let key = ObjectIdentifier(asyncChannel.channel)
    try await asyncChannel.executeThenClose { inbound, outbound in
      let writer = FrameWriter(outbound)
      let connection = ServerConnection(
        protocolName: protocolName, writer: writer, handlers: handlers, limits: limits,
        peerUID: peerUID)
      openConnections[key] = OpenConnection(channel: asyncChannel.channel, writer: writer)
      defer { openConnections[key] = nil }
      do {
        for try await frame in inbound {
          let keepOpen = await connection.handle(frame: frame)
          if !keepOpen { break }
        }
      } catch {
        // Decoder threw or the peer vanished; fall through to shutdown.
      }
      await connection.shutdown()
    }
  }

  /// Pushes an unsolicited `event` envelope to every connected peer.
  public func broadcast(event method: String, payload: JSONValue? = nil) async {
    let envelope = Envelope.event(
      protocolName, requestId: UUID().uuidString.lowercased(), method: method, payload: payload)
    for connection in openConnections.values {
      await connection.writer.sendDetached(envelope)
    }
  }
}

struct OpenConnection: Sendable {
  let channel: any Channel
  let writer: FrameWriter
}

/// Closes the connection when `IdleStateHandler` reports the read timeout elapsed.
final class IdleCloseHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is IdleStateHandler.IdleStateEvent {
      context.close(promise: nil)
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }
}
