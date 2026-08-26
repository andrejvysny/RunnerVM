import Foundation
import NIOCore

enum MethodHandler: Sendable {
  case unary(MethodClass, @Sendable (Envelope, RequestContext) async throws -> JSONValue)
  case stream(MethodClass, @Sendable (Envelope, RequestContext, StreamSink) async throws -> Void)

  var methodClass: MethodClass {
    switch self {
    case .unary(let methodClass, _), .stream(let methodClass, _): return methodClass
    }
  }
}

/// Per-connection request dispatch, budgets and cancellation bookkeeping.
actor ServerConnection {
  private let protocolName: RPCProtocol
  private let writer: FrameWriter
  private let handlers: [String: MethodHandler]
  private let limits: ConnectionLimits
  private let peerUID: uid_t
  private var inFlight: [String: Task<Void, Never>] = [:]

  init(
    protocolName: RPCProtocol, writer: FrameWriter, handlers: [String: MethodHandler],
    limits: ConnectionLimits, peerUID: uid_t
  ) {
    self.protocolName = protocolName
    self.writer = writer
    self.handlers = handlers
    self.limits = limits
    self.peerUID = peerUID
  }

  /// Returns false when the connection must be torn down.
  func handle(frame: ByteBuffer) async -> Bool {
    let decoded: Result<Envelope, EnvelopeError> = frame.withUnsafeReadableBytes { bytes in
      do { return .success(try Envelope.decode(from: bytes, expecting: protocolName)) } catch let error
        as EnvelopeError
      { return .failure(error) } catch { return .failure(EnvelopeError(.malformed, "\(error)")) }
    }
    switch decoded {
    case .failure(let error): return await reject(error)
    case .success(let envelope): return await route(envelope)
    }
  }

  private func reject(_ error: EnvelopeError) async -> Bool {
    guard let requestId = error.requestId else { return false }
    await writer.sendDetached(
      .failure(protocolName, requestId: requestId, error: error.payload))
    // A version or protocol disagreement is fatal for the whole connection, not just this frame.
    return error.code != .protocolVersion && error.code != .protocolMismatch
  }

  private func route(_ envelope: Envelope) async -> Bool {
    switch envelope.kind {
    case .request:
      await start(envelope)
    case .cancel:
      inFlight[envelope.requestId]?.cancel()
    case .event:
      break
    case .response, .chunk:
      await writer.sendDetached(
        .failure(
          protocolName, requestId: envelope.requestId,
          error: RPCErrorPayload(code: .malformed, message: "clients may not send \(envelope.kind.rawValue)")))
    }
    return true
  }

  private func start(_ envelope: Envelope) async {
    let requestId = envelope.requestId
    guard let method = envelope.method, let handler = handlers[method] else {
      await writer.sendDetached(
        .failure(
          protocolName, requestId: requestId, method: envelope.method,
          error: RPCErrorPayload(code: .unknownMethod, message: "unknown method '\(envelope.method ?? "")'")))
      return
    }
    guard inFlight[requestId] == nil else {
      await writer.sendDetached(
        .failure(
          protocolName, requestId: requestId, method: method,
          error: RPCErrorPayload(code: .malformed, message: "duplicate requestId")))
      return
    }
    guard inFlight.count < limits.maxInFlight else {
      await writer.sendDetached(
        .failure(
          protocolName, requestId: requestId, method: method,
          error: RPCErrorPayload(code: .busy, message: "in-flight limit reached", retryable: true)))
      return
    }
    let context = RequestContext(
      protocolName: protocolName, requestId: requestId, method: method,
      methodClass: handler.methodClass, peerUID: peerUID)
    // No suspension between task creation and registration, so cancel/cleanup cannot race.
    inFlight[requestId] = Task { await self.execute(envelope, handler: handler, context: context) }
  }

  private func execute(
    _ envelope: Envelope, handler: MethodHandler, context: RequestContext
  ) async {
    switch handler {
    case .unary(_, let body): await runUnary(envelope, context: context, body: body)
    case .stream(_, let body): await runStream(envelope, context: context, body: body)
    }
    inFlight[context.requestId] = nil
  }

  private func runUnary(
    _ envelope: Envelope, context: RequestContext,
    body: @Sendable (Envelope, RequestContext) async throws -> JSONValue
  ) async {
    do {
      let payload = try await body(envelope, context)
      await writer.sendDetached(
        .response(
          protocolName, requestId: context.requestId, method: context.method, payload: payload))
    } catch {
      await writer.sendDetached(
        .failure(
          protocolName, requestId: context.requestId, method: context.method,
          error: ServerConnection.payload(for: error)))
    }
  }

  private func runStream(
    _ envelope: Envelope, context: RequestContext,
    body: @Sendable (Envelope, RequestContext, StreamSink) async throws -> Void
  ) async {
    let sink = StreamSink(
      writer: writer, protocolName: protocolName, requestId: context.requestId,
      method: context.method, maxBytes: limits.maxStreamBytesPerRequest)
    do {
      try await body(envelope, context, sink)
      await sink.finish(error: nil)
    } catch {
      await sink.finish(error: ServerConnection.payload(for: error))
    }
  }

  static func payload(for error: any Error) -> RPCErrorPayload {
    switch error {
    case is CancellationError:
      return RPCErrorPayload(code: .cancelled, message: "request cancelled")
    case let callError as RPCCallError:
      if let remote = callError.payload { return remote }
      return RPCErrorPayload(
        code: callError.code ?? .internalError, message: String(describing: callError))
    case let envelopeError as EnvelopeError:
      return envelopeError.payload
    default:
      return RPCErrorPayload(code: .internalError, message: String(describing: error))
    }
  }

  /// Cancels every outstanding handler and stops accepting writes.
  func shutdown() async {
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll()
    await writer.finish()
  }
}
