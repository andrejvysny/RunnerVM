import Foundation
import Persistence
import RunnerCore

/// Failures that abort daemon startup or an orchestration operation.
public enum OrchestrationError: RunnerError {
  case daemonAlreadyRunning(path: String)
  case lockUnavailable(path: String, errno: Int32)
  case hostIdentityUnwritable(path: String, reason: String)
  case configUnreadable(path: String, reason: String)
  case configRejected(issues: [ConfigurationIssue])
  case notStarted
  case alreadyStarted
  case profileDisabled(name: String)
  case instanceUnknown(id: String)
  case instanceNotStoppable(id: String, state: String)
  case instanceNotDeletable(id: String, state: String)
  /// The host cannot take the request and no single `SchedulerError` describes why.
  case capacityRejected(reasons: [String])
  /// Free space is at or below the configured floor (spec §17 "stop admitting new work").
  case diskPressureCritical(freeBytes: UInt64, floorBytes: UInt64)
  /// No usable GitHub credential or no applied configuration behind it (spec §12).
  case githubNotConfigured(reason: String)
  /// The scope's persisted health forbids placing work there (spec §134, §135).
  case scopeNotSchedulable(name: String, health: String, detail: String?)
  case instanceNotIdle(id: String, state: String)
  case runnerSessionUnknown(id: String)
  case runnerSessionActive(instance: String, session: String)
  /// `debug.demandSet` against a daemon whose demand comes from GitHub statistics.
  case demandNotManual
  /// `debug.scaleSetReconnect` against a daemon whose demand does not come from a scale set.
  case demandNotScaleSet
  /// A scale-set operation was asked for before the profile had a registered scale set.
  case scaleSetNotRegistered(profile: String)
  /// `instance.create {purpose: maintenance}` with no `ttlMs`. A pinned VM the scheduler will
  /// never reclaim needs a deadline, or a forgotten smoke test holds host capacity forever.
  case maintenanceTTLRequired
  /// `ttlMs` outside `MaintenanceTTL.bounds`.
  case maintenanceTTLInvalid(ttlMs: Int64, minimumMs: Int64, maximumMs: Int64)
  /// `imageOverride` on a runner create. A runner VM must always be the image its profile names,
  /// otherwise `scaleset.list` and the image-update machinery describe a fleet that is not there.
  case imageOverrideMaintenanceOnly

  public var code: String {
    switch self {
    case .daemonAlreadyRunning: "DAEMON_ALREADY_RUNNING"
    case .lockUnavailable: "DAEMON_LOCK_UNAVAILABLE"
    case .hostIdentityUnwritable: "HOST_IDENTITY_UNWRITABLE"
    case .configUnreadable: "CONFIG_FILE_UNREADABLE"
    case .configRejected: "CONFIG_VALIDATION_FAILED"
    case .notStarted: "DAEMON_NOT_STARTED"
    case .alreadyStarted: "DAEMON_ALREADY_STARTED"
    case .profileDisabled: "PROFILE_DISABLED"
    case .instanceUnknown: "INSTANCE_NOT_FOUND"
    case .instanceNotStoppable: "INSTANCE_NOT_STOPPABLE"
    case .instanceNotDeletable: "INSTANCE_NOT_DELETABLE"
    case .capacityRejected: "SCHEDULER_CAPACITY_REJECTED"
    case .diskPressureCritical: "DISK_PRESSURE"
    case .githubNotConfigured: "GITHUB_NOT_CONFIGURED"
    case .scopeNotSchedulable: "GITHUB_SCOPE_NOT_SCHEDULABLE"
    case .instanceNotIdle: "INSTANCE_NOT_IDLE"
    case .runnerSessionUnknown: "RUNNER_SESSION_NOT_FOUND"
    case .runnerSessionActive: "RUNNER_SESSION_ALREADY_ACTIVE"
    case .demandNotManual: "DEMAND_NOT_MANUAL"
    case .demandNotScaleSet: "DEMAND_NOT_SCALE_SET"
    case .scaleSetNotRegistered: "SCALE_SET_NOT_REGISTERED"
    case .maintenanceTTLRequired: "MAINTENANCE_TTL_REQUIRED"
    case .maintenanceTTLInvalid: "MAINTENANCE_TTL_INVALID"
    case .imageOverrideMaintenanceOnly: "IMAGE_OVERRIDE_MAINTENANCE_ONLY"
    }
  }

  public var message: String {
    switch self {
    case let .daemonAlreadyRunning(path):
      "another runnerd holds the lock at \(path)"
    case let .lockUnavailable(path, code):
      "cannot lock \(path): \(String(cString: strerror(code)))"
    case let .hostIdentityUnwritable(path, reason):
      "cannot persist the host id at \(path): \(reason)"
    case let .configUnreadable(path, reason):
      "cannot read configuration at \(path): \(reason)"
    case let .configRejected(issues):
      "configuration rejected: " + issues.map { "\($0.path): \($0.code)" }.joined(separator: ", ")
    case .notStarted: "the daemon runtime has not been started"
    case .alreadyStarted: "the daemon runtime is already running"
    case let .profileDisabled(name):
      "profile '\(name)' is disabled"
    case let .instanceUnknown(id):
      "instance '\(id)' not found"
    case let .instanceNotStoppable(id, state):
      "instance \(id) cannot be stopped from state '\(state)'"
    case let .instanceNotDeletable(id, state):
      "instance \(id) cannot be deleted from state '\(state)'"
    case let .capacityRejected(reasons):
      "the host cannot admit this instance: " + reasons.joined(separator: ", ")
    case let .diskPressureCritical(free, floor):
      "free disk \(ByteSize(bytes: free)) is at or below the \(ByteSize(bytes: floor)) floor; " +
        "refusing to admit new instances"
    case let .githubNotConfigured(reason):
      "GitHub is not configured: \(reason)"
    case let .scopeNotSchedulable(name, health, detail):
      "scope '\(name)' is \(health)" + (detail.map { ": \($0)" } ?? "")
    case let .instanceNotIdle(id, state):
      "instance \(id) is '\(state)'; a runner session can only start from 'idle'"
    case let .runnerSessionUnknown(id):
      "runner session '\(id)' not found"
    case let .runnerSessionActive(instance, session):
      "instance \(instance) already runs session \(session)"
    case .demandNotManual:
      "demand is driven by GitHub scale-set statistics; " +
        "set github.demand: manual in the configuration and restart runnerd to set it by hand"
    case .demandNotScaleSet:
      "demand is not driven by a GitHub scale set; there is no message session to reconnect"
    case let .scaleSetNotRegistered(profile):
      "profile '\(profile)' has no registered GitHub scale set yet"
    case .maintenanceTTLRequired:
      "a maintenance instance must carry a ttl; the scheduler never reclaims one on its own"
    case let .maintenanceTTLInvalid(ttl, minimum, maximum):
      "maintenance ttl \(ttl)ms is outside \(minimum)ms...\(maximum)ms"
    case .imageOverrideMaintenanceOnly:
      "an image override is only allowed with purpose 'maintenance'"
    }
  }

  /// Disk pressure clears on its own once space frees up, unlike a rejected capacity request.
  public var retryable: Bool {
    if case .diskPressureCritical = self { return true }
    return false
  }
}

/// Build identity reported by `system.version` and `system.status`.
public enum RunnerVMBuild {
  /// One constant, shared with `runnerctl --version` (which must answer without a daemon).
  public static let version = RunnerVMVersion.current
  /// Highest SQLite schema version this build migrates to (`Persistence.Migrator`).
  public static let schemaVersion = PersistenceSchema.currentVersion
}
