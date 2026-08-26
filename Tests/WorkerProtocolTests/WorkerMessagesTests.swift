import Foundation
import RPC
import RunnerCore
import Testing
@testable import WorkerProtocol

@Suite struct WorkerMethodTests {
  /// The catalogue is the contract runnerd retries against; a method silently changing class would
  /// turn a safe retry into a double mutation.
  @Test func classesMatchTheProtocolTable() {
    let expected: [WorkerMethod: MethodClass] = [
      .hello: .readOnly, .status: .readOnly, .vmState: .readOnly,
      .agentBridgeStatus: .readOnly, .hostCapabilities: .readOnly,
      .lease: .idempotentMutation, .vmStart: .idempotentMutation,
      .vmRequestStop: .idempotentMutation, .vmForceStop: .idempotentMutation,
      .shutdown: .singleShot,
    ]
    #expect(WorkerMethod.allCases.count == expected.count)
    for method in WorkerMethod.allCases {
      #expect(method.methodClass == expected[method], "\(method.rawValue)")
    }
  }

  @Test func wireNamesAreStable() {
    #expect(WorkerMethod.allCases.map(\.rawValue).sorted() == [
      "agent.bridgeStatus", "host.capabilities", "vm.forceStop", "vm.requestStop", "vm.start",
      "vm.state", "worker.hello", "worker.lease", "worker.shutdown", "worker.status",
    ])
    #expect(WorkerEvent.vmStateChanged.rawValue == "vm.stateChanged")
    #expect(WorkerEvent.vmError.rawValue == "vm.error")
    #expect(WorkerProtocolVersion.current == 1)
  }

  @Test func exitCodesMatchTheProtocolDocument() {
    #expect(WorkerExitCode.clean.rawValue == 0)
    #expect(WorkerExitCode.usage.rawValue == 64)
    #expect(WorkerExitCode.specInvalid.rawValue == 65)
    #expect(WorkerExitCode.lockHeld.rawValue == 75)
    #expect(WorkerExitCode.vzConfigInvalid.rawValue == 76)
    #expect(WorkerExitCode.vzStartFailed.rawValue == 77)
  }
}

@Suite struct WorkerCodingTests {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try WorkerCoding.decode(T.self, from: WorkerCoding.payload(value))
  }

  @Test func helloRoundTrips() throws {
    let hello = HelloResponse(
      instanceId: InstanceID(rawValue: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"), generation: 7,
      incarnationNonce: "deadbeef", specDigest: String(repeating: "a", count: 64), pid: 4242,
      vmState: .running, agentBootId: "boot-1")
    #expect(try roundTrip(hello) == hello)
    let payload = try WorkerCoding.payload(hello)
    #expect(payload["protocolVersion"]?.intValue == 1)
    #expect(payload["instanceId"]?.stringValue == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    #expect(payload["vmState"]?.stringValue == "running")
  }

  @Test func helloOmitsAbsentAgentBootId() throws {
    let hello = HelloResponse(
      instanceId: InstanceID(rawValue: "i"), generation: 0, incarnationNonce: "n", specDigest: "d",
      pid: 1, vmState: .stopped)
    #expect(try WorkerCoding.payload(hello)["agentBootId"] == nil)
    #expect(try roundTrip(hello) == hello)
  }

  /// Proto/envelope.md: timestamps are RFC 3339 strings with `Z`, never reference-epoch doubles.
  @Test func timestampsAreRFC3339() throws {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(try WorkerCoding.payload(LeaseResponse(leaseExpiresAt: instant))["leaseExpiresAt"]
      == .string("2023-11-14T22:13:20Z"))
    let event = VMStateChangedEvent(vmState: .stopping, at: instant)
    #expect(try WorkerCoding.payload(event)["at"] == .string("2023-11-14T22:13:20Z"))
    #expect(try roundTrip(event) == event)
  }

  @Test func statusRoundTripsWithAndWithoutOptionals() throws {
    let busy = StatusResponse(
      vmState: .running, uptimeMs: 90_000, leaseExpiresAt: Date(timeIntervalSince1970: 1_700_000_000),
      bridgeConnections: 2, lastError: nil)
    #expect(try roundTrip(busy) == busy)
    let failed = StatusResponse(
      vmState: .error, uptimeMs: 1, leaseExpiresAt: nil, bridgeConnections: 0, lastError: "boom")
    #expect(try roundTrip(failed) == failed)
    #expect(try WorkerCoding.payload(busy)["uptimeMs"] == .int(90_000))
  }

  @Test func requestsRoundTrip() throws {
    #expect(try roundTrip(LeaseRequest(ttlMs: 30_000)) == LeaseRequest(ttlMs: 30_000))
    let drain = ShutdownRequest(reason: .drain, gracefulTimeoutMs: 45_000)
    #expect(try roundTrip(drain) == drain)
    #expect(try WorkerCoding.payload(drain)["reason"] == .string("drain"))
    #expect(try roundTrip(VMStateResponse(vmState: .stopping)).vmState == .stopping)
    #expect(try roundTrip(RequestStopResponse(accepted: false)).accepted == false)
    let bridge = BridgeStatusResponse(socketPath: "/tmp/vm-abc-agent.sock", activeConnections: 1)
    #expect(try roundTrip(bridge) == bridge)
    let error = VMErrorEvent(code: "VM_ERROR", message: "guest panicked")
    #expect(try roundTrip(error) == error)
  }

  @Test func emptyPayloadDecodesIntoADefaultedRequest() throws {
    #expect(throws: (any Error).self) { try WorkerCoding.decode(LeaseRequest.self, from: nil) }
    #expect(try WorkerCoding.decode(EmptyPayload.self, from: nil) == EmptyPayload())
  }

  @Test func vmStatesCoverTheWireVocabulary() {
    let states: [WorkerVMState] = [.stopped, .starting, .running, .stopping, .error]
    #expect(states.map(\.rawValue) == ["stopped", "starting", "running", "stopping", "error"])
    #expect(WorkerVMState(rawValue: "paused") == nil)
  }
}

private struct EmptyPayload: Codable, Equatable {}
