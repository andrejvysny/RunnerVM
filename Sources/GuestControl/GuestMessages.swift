import Foundation

// MARK: - agent.hello

/// `agent.hello` → identity and capability advertisement.
///
/// `bootId` is the guest's boot identity: it changes on every guest boot, which is how runnerd
/// detects a reboot it did not order (spec §35).
public struct HelloResponse: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var agentVersion: String
  public var os: String
  public var arch: String
  public var hostname: String
  public var bootId: String
  public var capabilities: [String]

  public init(
    protocolVersion: Int = GuestProtocolVersion.current, agentVersion: String, os: String,
    arch: String, hostname: String, bootId: String, capabilities: [String] = []
  ) {
    self.protocolVersion = protocolVersion
    self.agentVersion = agentVersion
    self.os = os
    self.arch = arch
    self.hostname = hostname
    self.bootId = bootId
    self.capabilities = capabilities
  }

  public func has(capability: String) -> Bool { capabilities.contains(capability) }
}

// MARK: - agent.health

public enum GuestHealthState: String, Codable, Sendable, CaseIterable, Hashable {
  case starting
  case ready
  case degraded
  case shuttingDown
}

/// `agent.health` → readiness. `reasons` is always present (possibly empty) so the host never has
/// to distinguish `null` from `[]`.
public struct HealthResponse: Codable, Sendable, Equatable {
  public var state: GuestHealthState
  public var reasons: [String]

  public init(state: GuestHealthState, reasons: [String] = []) {
    self.state = state
    self.reasons = reasons
  }

  public var isReady: Bool { state == .ready }
}

// MARK: - agent.getInfo

/// `agent.getInfo` → the guest facts runnerd shows in `vm show` and `vm ssh`.
public struct GuestInfo: Codable, Sendable, Equatable {
  public var ipAddresses: [String]
  public var uptimeSec: Int64
  public var kernel: String
  /// Omitted by the agent when the actions runner is not installed.
  public var runnerVersion: String?
  /// Omitted by the agent when Docker is not installed.
  public var dockerVersion: String?

  public init(
    ipAddresses: [String], uptimeSec: Int64, kernel: String, runnerVersion: String? = nil,
    dockerVersion: String? = nil
  ) {
    self.ipAddresses = ipAddresses
    self.uptimeSec = uptimeSec
    self.kernel = kernel
    self.runnerVersion = runnerVersion
    self.dockerVersion = dockerVersion
  }
}

// MARK: - agent.resizeDisk

/// `agent.resizeDisk` → whether the root filesystem grew into the space the host allocated.
/// `grown: false` with an unchanged `rootBytes` means "already at size", not a failure.
public struct ResizeDiskResponse: Codable, Sendable, Equatable {
  public var grown: Bool
  public var rootBytes: Int64

  public init(grown: Bool, rootBytes: Int64) {
    self.grown = grown
    self.rootBytes = rootBytes
  }
}
