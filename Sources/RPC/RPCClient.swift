import Foundation
import NIOCore
import NIOPosix

/// Length-prefixed JSON RPC client for one Unix-domain socket connection.
public actor RPCClient {
  private enum Sink {
    case unary(CheckedContinuation<JSONValue, any Error>)
    case stream(AsyncThrowingStream<JSONValue, any Error>.Continuation)
  }

  private struct PendingCall {
    let sink: Sink
    var deadlineTask: Task<Void, Never>?
    var lastSeq: Int64?
  }

  private let protocolName: RPCProtocol
  private let limits: ConnectionLimits
  private let eventContinuation: AsyncStream<Envelope>.Continuation
  /// Unsolicited envelopes the peer pushed without a matching local request.
  public nonisolated let events: AsyncStream<Envelope>

  private var writer: FrameWriter?
  private var channel: (any Channel)?
  private var readerTask: Task<Void, Never>?
  private var pending: [String: PendingCall] = [:]
  private var attachWaiter: CheckedContinuation<Void, Never>?
  private var attached = false
  private var disconnected = false

  private init(protocolName: RPCProtocol, limits: ConnectionLimits) {
    self.protocolName = protocolName
    self.limits = limits
    (events, eventContinuation) = AsyncStream<Envelope>.makeStream(bufferingPolicy: .unbounded)
  }

  public static func connect(
    protocol protocolName: RPCProtocol,
    socketPath: URL,
    limits: ConnectionLimits = ConnectionLimits()
  ) async throws -> RPCClient {
    let client = RPCClient(protocolName: protocolName, limits: limits)
    let cap = protocolName.frameCap
    let asyncChannel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connect(unixDomainSocketPath: socketPath.path) { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(FrameDecoder(maxFrameLength: cap)),
            MessageToByteHandler(FrameEncoder(maxFrameLength: cap)),
          ])
          return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }
      }
    await client.startReading(asyncChannel)
    return client
  }

  private func startReading(_ asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
    readerTask = Task { [weak self] in
      do {
        try await asyncChannel.executeThenClose { inbound, outbound in
          await self?.attach(writer: FrameWriter(outbound), channel: asyncChannel.channel)
          for try await frame in inbound {
            await self?.receive(frame: frame)
          }
        }
      } catch {
        // Framing error or reset; every outstanding call fails below.
      }
      await self?.handleDisconnect()
    }
    // The writer must exist before `connect` returns, otherwise the first call races the reader.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if attached {
        continuation.resume()
      } else {
        attachWaiter = continuation
      }
    }
  }

  private func attach(writer: FrameWriter, channel: any Channel) {
    self.writer = writer
    self.channel = channel
    attached = true
    attachWaiter?.resume()
    attachWaiter = nil
  }

  // MARK: - Calls

  public func call(
    method: String, payload: JSONValue? = nil, deadline: Duration? = nil
  ) async throws -> JSONValue {
    guard !disconnected else { throw RPCCallError.disconnected }
    guard pending.count < limits.maxInFlight else { throw RPCCallError.tooManyInFlight }
    let requestId = UUID().uuidString.lowercased()
    let envelope = Envelope.request(
      protocolName, requestId: requestId, method: method, payload: payload)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[requestId] = PendingCall(sink: .unary(continuation))
        armDeadline(requestId, deadline)
        Task { await self.transmit(envelope, requestId: requestId) }
      }
    } onCancel: {
      Task { await self.abort(requestId, with: .cancelled, notifyPeer: true) }
    }
  }

  public nonisolated func stream(
    method: String, payload: JSONValue? = nil
  ) -> AsyncThrowingStream<JSONValue, any Error> {
    let requestId = UUID().uuidString.lowercased()
    let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream(
      bufferingPolicy: .unbounded)
    continuation.onTermination = { [weak self] reason in
      guard case .cancelled = reason, let self else { return }
      Task { await self.abort(requestId, with: .cancelled, notifyPeer: true) }
    }
    Task {
      await self.startStream(
        requestId: requestId, method: method, payload: payload, continuation: continuation)
    }
    return stream
  }

  private func startStream(
    requestId: String, method: String, payload: JSONValue?,
    continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
  ) async {
    guard !disconnected else {
      continuation.finish(throwing: RPCCallError.disconnected)
      return
    }
    guard pending.count < limits.maxInFlight else {
      continuation.finish(throwing: RPCCallError.tooManyInFlight)
      return
    }
    pending[requestId] = PendingCall(sink: .stream(continuation))
    await transmit(
      Envelope.request(protocolName, requestId: requestId, method: method, payload: payload),
      requestId: requestId)
  }

  private func transmit(_ envelope: Envelope, requestId: String) async {
    guard let writer else {
      abortLocally(requestId, with: .disconnected)
      return
    }
    do {
      try await writer.send(envelope)
    } catch {
      abortLocally(requestId, with: .disconnected)
    }
  }

  private func armDeadline(_ requestId: String, _ deadline: Duration?) {
    guard let deadline else { return }
    pending[requestId]?.deadlineTask = Task { [weak self] in
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled else { return }
      await self?.abort(requestId, with: .deadlineExceeded, notifyPeer: true)
    }
  }

  // MARK: - Inbound

  private func receive(frame: ByteBuffer) async {
    let decoded: Envelope? = frame.withUnsafeReadableBytes { bytes in
      try? Envelope.decode(from: bytes, expecting: protocolName)
    }
    guard let envelope = decoded else {
      channel?.close(promise: nil)
      return
    }
    switch envelope.kind {
    case .event:
      eventContinuation.yield(envelope)
    case .response:
      complete(envelope)
    case .chunk:
      deliver(envelope)
    case .request, .cancel:
      eventContinuation.yield(envelope)
    }
  }

  private func complete(_ envelope: Envelope) {
    guard let call = removePending(envelope.requestId) else { return }
    switch call.sink {
    case .unary(let continuation):
      if let error = envelope.error {
        continuation.resume(throwing: RPCCallError.remote(error))
      } else {
        continuation.resume(returning: envelope.payload ?? .emptyObject)
      }
    case .stream(let continuation):
      // A response instead of chunks still terminates the stream.
      continuation.finish(throwing: envelope.error.map { RPCCallError.remote($0) })
    }
  }

  private func deliver(_ envelope: Envelope) {
    guard let call = pending[envelope.requestId], let seq = envelope.streamSeq else { return }
    guard case .stream(let continuation) = call.sink else {
      abortLocally(envelope.requestId, with: .protocolViolation("chunk for a unary request"))
      return
    }
    if let last = call.lastSeq, seq <= last {
      abortLocally(envelope.requestId, with: .protocolViolation("streamSeq \(seq) after \(last)"))
      return
    }
    pending[envelope.requestId]?.lastSeq = seq
    if envelope.end == true {
      _ = removePending(envelope.requestId)
      continuation.finish(throwing: envelope.error.map { RPCCallError.remote($0) })
      return
    }
    continuation.yield(envelope.payload ?? .emptyObject)
  }

  // MARK: - Teardown

  private func removePending(_ requestId: String) -> PendingCall? {
    guard let call = pending.removeValue(forKey: requestId) else { return nil }
    call.deadlineTask?.cancel()
    return call
  }

  private func abort(_ requestId: String, with error: RPCCallError, notifyPeer: Bool) async {
    guard pending[requestId] != nil else { return }
    if notifyPeer, let writer {
      try? await writer.send(Envelope.cancel(protocolName, requestId: requestId))
    }
    abortLocally(requestId, with: error)
  }

  private func abortLocally(_ requestId: String, with error: RPCCallError) {
    guard let call = removePending(requestId) else { return }
    switch call.sink {
    case .unary(let continuation): continuation.resume(throwing: error)
    case .stream(let continuation): continuation.finish(throwing: error)
    }
  }

  private func handleDisconnect() async {
    guard !disconnected else { return }
    disconnected = true
    attachWaiter?.resume()
    attachWaiter = nil
    attached = true
    for requestId in Array(pending.keys) {
      abortLocally(requestId, with: .disconnected)
    }
    eventContinuation.finish()
    writer = nil
  }

  public func close() async {
    await writer?.finish()
    channel?.close(promise: nil)
    await handleDisconnect()
    readerTask?.cancel()
    readerTask = nil
  }
}
