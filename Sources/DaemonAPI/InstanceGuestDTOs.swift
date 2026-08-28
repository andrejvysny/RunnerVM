import Foundation
import GuestControl

// MARK: - instance.exec

/// `instance.exec` request. The daemon forwards `argv` verbatim to `agent.exec`; both bounds are
/// mandatory because an unbounded exec against an untrusted guest is a denial-of-service surface.
public struct InstanceExecRequest: Codable, Sendable, Hashable {
  public var id: String
  public var argv: [String]
  public var cwd: String?
  public var timeoutMs: Int64
  public var maxOutputBytes: Int64

  public init(
    id: String, argv: [String], cwd: String? = nil,
    timeoutMs: Int64 = ExecRequest.defaultTimeoutMs,
    maxOutputBytes: Int64 = ExecRequest.defaultMaxOutputBytes
  ) {
    self.id = id
    self.argv = argv
    self.cwd = cwd
    self.timeoutMs = timeoutMs
    self.maxOutputBytes = maxOutputBytes
  }
}

/// One output chunk of `instance.exec`. `data` is base64 on the wire, matching `agent.exec`.
public struct InstanceExecChunk: Codable, Sendable, Hashable {
  public var stream: String
  public var data: Data

  public init(stream: String, data: Data) {
    self.stream = stream
    self.data = data
  }
}

/// The last payload-bearing `instance.exec` chunk; the RPC layer appends the empty `end: true`
/// frame after it.
public struct InstanceExecResult: Codable, Sendable, Hashable {
  public var exitCode: Int32

  public init(exitCode: Int32) { self.exitCode = exitCode }
}

/// What `DaemonClient.instanceExec` yields: output chunks, then exactly one `exited`.
public enum InstanceExecEvent: Sendable, Hashable {
  case chunk(InstanceExecChunk)
  case exited(Int32)
}

// MARK: - instance.metrics

public struct InstanceMetricsRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

/// Spec §40: both halves of a VM's telemetry — what the guest reports about itself and what the
/// host can observe about the `vmworker` process backing it.
public struct InstanceMetricsResponse: Codable, Sendable, Equatable {
  public var instanceId: String
  public var collectedAt: String
  public var guest: GuestMetrics
  /// Absent when no worker is connected or `proc_pidinfo` refused the pid.
  public var worker: WorkerProcessMetrics?

  public init(
    instanceId: String, collectedAt: String, guest: GuestMetrics,
    worker: WorkerProcessMetrics? = nil
  ) {
    self.instanceId = instanceId
    self.collectedAt = collectedAt
    self.guest = guest
    self.worker = worker
  }
}

/// Host-observed slice of one `vmworker` process.
public struct WorkerProcessMetrics: Codable, Sendable, Hashable {
  public var pid: Int32
  public var rssBytes: UInt64
  /// User + system CPU consumed since the process started.
  public var cpuSeconds: Double

  public init(pid: Int32, rssBytes: UInt64, cpuSeconds: Double) {
    self.pid = pid
    self.rssBytes = rssBytes
    self.cpuSeconds = cpuSeconds
  }
}

// MARK: - instance.selfTest

/// `instance.selfTest`. Relays `agent.selfTest` to the instance's guest agent exactly as
/// `instance.metrics` relays `agent.getMetrics`; the answer is the guest's `SelfTestResult`
/// verbatim, so runnerctl and the daemon can never disagree about what the guest reported.
public struct InstanceSelfTestRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

// MARK: - instance.sshInfo

public struct InstanceSSHInfoRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

/// Enough to build an `ssh` command line. `sshEnabled` is the profile's policy, not a probe of the
/// guest's sshd: a disabled profile must not be handed a connection string at all.
public struct InstanceSSHInfo: Codable, Sendable, Hashable {
  public var ipAddresses: [String]
  public var user: String
  public var sshEnabled: Bool

  public init(ipAddresses: [String], user: String, sshEnabled: Bool) {
    self.ipAddresses = ipAddresses
    self.user = user
    self.sshEnabled = sshEnabled
  }

  /// The account the guest image provisions for interactive debugging (spec §38).
  public static let defaultUser = "runner"

  public var command: String? {
    guard sshEnabled, let address = ipAddresses.first else { return nil }
    return "ssh \(user)@\(address)"
  }
}
