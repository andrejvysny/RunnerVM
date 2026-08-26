import Foundation
import RunnerCore

/// Every file an instance directory owns (spec §22, §74). Pure path algebra: nothing here touches
/// disk, so the daemon, the worker supervisor and the sealer all agree on names without stat'ing.
public struct VMInstanceLayout: Sendable, Equatable {
  public static let diskName = "disk.img"
  public static let nvramName = "nvram.bin"
  public static let specName = "spec.json"
  public static let serialLogName = "serial.log"
  public static let workerLogName = "worker.log"
  public static let workerLockName = "worker.lock"
  public static let failureName = "failure.json"

  public let instanceId: InstanceID
  public let directory: URL
  public let disk: URL
  /// Absent for a Linux instance whose image ships no EFI store — vmworker creates a fresh one, and
  /// a fresh store is the correct default because EFI variables are instance state, not image state.
  public let nvram: URL?
  public let spec: URL
  public let serialLog: URL
  public let workerLog: URL
  /// Created once, at materialization, and never unlinked or replaced while the instance exists:
  /// the worker's `fcntl` write lock on this inode is the liveness proof runnerd fences on.
  public let workerLock: URL
  public let failure: URL

  public init(instanceId: InstanceID, directory: URL, hasNVRAM: Bool) {
    self.instanceId = instanceId
    self.directory = directory
    disk = directory.appending(path: Self.diskName)
    nvram = hasNVRAM ? Self.nvramPath(in: directory) : nil
    spec = directory.appending(path: Self.specName)
    serialLog = directory.appending(path: Self.serialLogName)
    workerLog = directory.appending(path: Self.workerLogName)
    workerLock = directory.appending(path: Self.workerLockName)
    failure = directory.appending(path: Self.failureName)
  }

  public static func nvramPath(in directory: URL) -> URL {
    directory.appending(path: nvramName)
  }

  public static func diskPath(in directory: URL) -> URL {
    directory.appending(path: diskName)
  }

  public static func workerLockPath(in directory: URL) -> URL {
    directory.appending(path: workerLockName)
  }

  /// Host-side diagnostics. Never part of a sealed image (spec §62).
  public static let diagnosticNames: Set<String> = [serialLogName, workerLogName, failureName]
}

/// `materialize` result. `cloneMethod` is reported separately from the layout because it describes
/// how this instance was produced, not where its files are, and it feeds `instance_clone_method` (§23).
public struct MaterializedInstance: Sendable, Equatable {
  public let layout: VMInstanceLayout
  public let cloneMethod: CloneMethod
}

/// `failure.json`: why a VM never came up, kept for the diagnostics retention window (spec §74).
public struct FailureRecord: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var instanceId: InstanceID
  /// Stable `RunnerError.code`, so retention and dashboards never parse prose.
  public var code: String
  public var message: String
  /// Lifecycle stage, e.g. "cloning", "bootingVM", "waitingForAgent".
  public var phase: String?
  public var retryable: Bool
  public var occurredAt: Date
  public var workerPID: Int32?
  public var details: [String: String]

  public init(
    schemaVersion: Int = FailureRecord.currentSchemaVersion, instanceId: InstanceID, code: String,
    message: String, phase: String? = nil, retryable: Bool = false, occurredAt: Date,
    workerPID: Int32? = nil, details: [String: String] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.instanceId = instanceId
    self.code = code
    self.message = message
    self.phase = phase
    self.retryable = retryable
    self.occurredAt = occurredAt
    self.workerPID = workerPID
    self.details = details
  }

  public init(
    instanceId: InstanceID, error: any RunnerError, phase: String? = nil, occurredAt: Date,
    workerPID: Int32? = nil, details: [String: String] = [:]
  ) {
    self.init(
      instanceId: instanceId, code: error.code, message: error.message, phase: phase,
      retryable: error.retryable, occurredAt: occurredAt, workerPID: workerPID, details: details
    )
  }
}
