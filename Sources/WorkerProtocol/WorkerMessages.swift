import Foundation
import RunnerCore

/// VM state as reported by vmworker. Mirrors VZVirtualMachine.State minus desktop-only states.
public enum WorkerVMState: String, Codable, Sendable {
  case stopped, starting, running, stopping, error
}

public struct HelloResponse: Codable, Sendable, Equatable {
  public var instanceId: InstanceID
  public var generation: Int
  public var incarnationNonce: String
  public var specDigest: String
  public var pid: Int32
  public var protocolVersion: Int
  public var vmState: WorkerVMState
  public var agentBootId: String?

  public init(
    instanceId: InstanceID, generation: Int, incarnationNonce: String, specDigest: String, pid: Int32,
    protocolVersion: Int = WorkerProtocolVersion.current, vmState: WorkerVMState, agentBootId: String? = nil
  ) {
    self.instanceId = instanceId
    self.generation = generation
    self.incarnationNonce = incarnationNonce
    self.specDigest = specDigest
    self.pid = pid
    self.protocolVersion = protocolVersion
    self.vmState = vmState
    self.agentBootId = agentBootId
  }
}

public struct StatusResponse: Codable, Sendable, Equatable {
  public var vmState: WorkerVMState
  public var uptimeMs: Int64
  public var leaseExpiresAt: Date?
  public var bridgeConnections: Int
  public var lastError: String?

  public init(vmState: WorkerVMState, uptimeMs: Int64, leaseExpiresAt: Date?, bridgeConnections: Int, lastError: String?) {
    self.vmState = vmState
    self.uptimeMs = uptimeMs
    self.leaseExpiresAt = leaseExpiresAt
    self.bridgeConnections = bridgeConnections
    self.lastError = lastError
  }
}

public struct LeaseRequest: Codable, Sendable, Equatable {
  public var ttlMs: Int64
  public init(ttlMs: Int64) { self.ttlMs = ttlMs }
}

public struct LeaseResponse: Codable, Sendable, Equatable {
  public var leaseExpiresAt: Date
  public init(leaseExpiresAt: Date) { self.leaseExpiresAt = leaseExpiresAt }
}

public struct VMStateResponse: Codable, Sendable, Equatable {
  public var vmState: WorkerVMState
  public init(vmState: WorkerVMState) { self.vmState = vmState }
}

public struct RequestStopResponse: Codable, Sendable, Equatable {
  public var accepted: Bool
  public init(accepted: Bool) { self.accepted = accepted }
}

public struct BridgeStatusResponse: Codable, Sendable, Equatable {
  public var socketPath: String
  public var activeConnections: Int
  public init(socketPath: String, activeConnections: Int) {
    self.socketPath = socketPath
    self.activeConnections = activeConnections
  }
}

public struct ShutdownRequest: Codable, Sendable, Equatable {
  public enum Reason: String, Codable, Sendable { case drain, stop }
  public var reason: Reason
  public var gracefulTimeoutMs: Int64
  public init(reason: Reason, gracefulTimeoutMs: Int64 = 30_000) {
    self.reason = reason
    self.gracefulTimeoutMs = gracefulTimeoutMs
  }
}

public struct VMStateChangedEvent: Codable, Sendable, Equatable {
  public var vmState: WorkerVMState
  public var at: Date
  public init(vmState: WorkerVMState, at: Date) {
    self.vmState = vmState
    self.at = at
  }
}

public struct VMErrorEvent: Codable, Sendable, Equatable {
  public var code: String
  public var message: String
  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

/// Worker process exit codes (Proto/worker_protocol.md).
public enum WorkerExitCode: Int32, Sendable {
  case clean = 0
  case usage = 64
  case specInvalid = 65
  case lockHeld = 75
  case vzConfigInvalid = 76
  case vzStartFailed = 77
}
