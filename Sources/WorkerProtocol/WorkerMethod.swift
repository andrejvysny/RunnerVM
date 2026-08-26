import RPC

/// Method catalogue of the `worker` protocol (Proto/worker_protocol.md). Shared by runnerd and vmworker.
public enum WorkerMethod: String, CaseIterable, Sendable {
  case hello = "worker.hello"
  case status = "worker.status"
  case lease = "worker.lease"
  case shutdown = "worker.shutdown"
  case vmStart = "vm.start"
  case vmRequestStop = "vm.requestStop"
  case vmForceStop = "vm.forceStop"
  case vmState = "vm.state"
  case agentBridgeStatus = "agent.bridgeStatus"
  case hostCapabilities = "host.capabilities"

  public var methodClass: MethodClass {
    switch self {
    case .hello, .status, .vmState, .agentBridgeStatus, .hostCapabilities: .readOnly
    case .lease, .vmStart, .vmRequestStop, .vmForceStop: .idempotentMutation
    case .shutdown: .singleShot
    }
  }
}

/// Unsolicited events emitted by vmworker (`kind: event`).
public enum WorkerEvent: String, Sendable {
  case vmStateChanged = "vm.stateChanged"
  case vmError = "vm.error"
}

public enum WorkerProtocolVersion {
  public static let current = 1
}
