import Foundation
import RPC
import VirtualizationCore
import WorkerProtocol

extension WorkerService {
  /// One dispatch point for the whole catalogue, so every method is answered on the main actor —
  /// the only place Virtualization.framework may be touched.
  func invoke(_ method: WorkerMethod, envelope: Envelope) async throws -> JSONValue {
    switch method {
    case .hello:
      return try WorkerCoding.payload(hello())
    case .status:
      return try WorkerCoding.payload(status())
    case .lease:
      let request: LeaseRequest = try decode(from: envelope)
      return try WorkerCoding.payload(LeaseResponse(leaseExpiresAt: renewLease(ttlMs: request.ttlMs)))
    case .vmStart:
      return try WorkerCoding.payload(VMStateResponse(vmState: try await startVM()))
    case .vmRequestStop:
      return try WorkerCoding.payload(RequestStopResponse(accepted: try requestStopVM()))
    case .vmForceStop:
      return try WorkerCoding.payload(VMStateResponse(vmState: try await forceStopVM()))
    case .vmState:
      return try WorkerCoding.payload(VMStateResponse(vmState: currentState))
    case .agentBridgeStatus:
      return try WorkerCoding.payload(bridgeStatus())
    case .shutdown:
      let request: ShutdownRequest = try decode(from: envelope)
      scheduleShutdown(request)
      return .emptyObject
    case .hostCapabilities:
      return try WorkerCoding.payload(HostCapabilities.probe())
    }
  }

  /// Decode failures are the caller's fault; report them as INVALID_PARAMS rather than INTERNAL.
  private func decode<T: Decodable>(from envelope: Envelope) throws -> T {
    do {
      return try WorkerCoding.decode(T.self, from: envelope.payload)
    } catch {
      throw EnvelopeError(.invalidParams, "invalid payload for \(envelope.method ?? "?"): \(error)")
    }
  }
}
