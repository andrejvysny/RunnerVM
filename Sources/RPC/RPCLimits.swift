import Foundation
import NIOCore

/// Catalogue classification, used by callers to decide whether a retry is safe.
public enum MethodClass: String, Sendable, Hashable, CaseIterable {
  case readOnly
  case idempotentMutation
  case singleShot
}

public struct ConnectionLimits: Sendable, Hashable {
  public var maxInFlight: Int
  public var idleTimeout: Duration
  /// Total encoded chunk bytes a single streaming request may emit; nil disables the budget.
  public var maxStreamBytesPerRequest: Int?

  public init(
    maxInFlight: Int = 16,
    idleTimeout: Duration = .seconds(60),
    maxStreamBytesPerRequest: Int? = 64 * 1024 * 1024
  ) {
    self.maxInFlight = maxInFlight
    self.idleTimeout = idleTimeout
    self.maxStreamBytesPerRequest = maxStreamBytesPerRequest
  }

  var idleTimeAmount: TimeAmount {
    let parts = idleTimeout.components
    return .nanoseconds(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
  }
}

/// Everything a handler learns about the request beyond its payload.
public struct RequestContext: Sendable, Hashable {
  public let protocolName: RPCProtocol
  public let requestId: String
  public let method: String
  public let methodClass: MethodClass
  public let peerUID: uid_t

  public init(
    protocolName: RPCProtocol, requestId: String, method: String, methodClass: MethodClass,
    peerUID: uid_t
  ) {
    self.protocolName = protocolName
    self.requestId = requestId
    self.method = method
    self.methodClass = methodClass
    self.peerUID = peerUID
  }
}

/// Serializes envelope writes for one connection so chunk order matches assignment order.
actor FrameWriter {
  private let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>
  private let allocator = ByteBufferAllocator()
  private var finished = false

  init(_ writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
    self.writer = writer
  }

  func send(_ envelope: Envelope) async throws {
    try await send(bytes: envelope.encode())
  }

  func send(bytes: [UInt8]) async throws {
    guard !finished else { throw RPCCallError.disconnected }
    var buffer = allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    try await writer.write(buffer)
  }

  /// Terminal frames must still reach the peer when the handler's task was cancelled, so the
  /// write runs in an unstructured task, which does not inherit cancellation.
  func sendDetached(_ envelope: Envelope) async {
    await Task { try? await self.send(envelope) }.value
  }

  func finish() {
    guard !finished else { return }
    finished = true
    writer.finish()
  }
}

/// Emits chunks for one streaming request. Send calls must come from a single task; the actor
/// serializes them but does not reorder concurrent callers.
public actor StreamSink {
  private let writer: FrameWriter
  private let protocolName: RPCProtocol
  private let requestId: String
  private let method: String
  private let maxBytes: Int?
  private var nextSeq: Int64 = 0
  private var bytesSent = 0
  private var closed = false

  init(
    writer: FrameWriter, protocolName: RPCProtocol, requestId: String, method: String,
    maxBytes: Int?
  ) {
    self.writer = writer
    self.protocolName = protocolName
    self.requestId = requestId
    self.method = method
    self.maxBytes = maxBytes
  }

  public func send(_ payload: JSONValue) async throws {
    guard !closed else { throw RPCCallError.disconnected }
    let envelope = Envelope.chunk(
      protocolName, requestId: requestId, method: method, streamSeq: nextSeq, end: false,
      payload: payload)
    let bytes = envelope.encode()
    if let maxBytes, bytesSent + bytes.count > maxBytes {
      throw RPCCallError.remote(
        RPCErrorPayload(code: .busy, message: "stream byte budget exhausted", retryable: false))
    }
    nextSeq += 1
    bytesSent += bytes.count
    try await writer.send(bytes: bytes)
  }

  /// Terminal chunk. Carries no payload of its own: the client treats it as control only.
  func finish(error: RPCErrorPayload?) async {
    guard !closed else { return }
    closed = true
    let envelope = Envelope.chunk(
      protocolName, requestId: requestId, method: method, streamSeq: nextSeq, end: true,
      payload: error == nil ? .emptyObject : nil, error: error)
    nextSeq += 1
    await writer.sendDetached(envelope)
  }
}
