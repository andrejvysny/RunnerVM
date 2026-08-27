import Foundation

/// `system.status` response, shaped after the operator-facing report in spec §103.
public struct SystemStatus: Codable, Sendable, Hashable {
  public var daemon: DaemonHealth
  public var host: HostSummary
  public var capacity: CapacitySummary
  public var github: GitHubSummary
  public var images: ImageSummary
  public var profiles: [ProfileRuntimeSummary]
  public var reconciliation: ReconciliationSummary
  public var diskPressure: DiskPressureSummary
  /// Phase 6. Optional for wire compat: a daemon that predates the image builder (or one that has
  /// never wired a builder into `DaemonServiceImpl`) simply omits the field, and the synthesized
  /// `Decodable` conformance leaves it `nil` rather than failing to decode.
  public var builds: BuildsSummary?

  public init(
    daemon: DaemonHealth,
    host: HostSummary,
    capacity: CapacitySummary,
    github: GitHubSummary,
    images: ImageSummary,
    profiles: [ProfileRuntimeSummary],
    reconciliation: ReconciliationSummary,
    diskPressure: DiskPressureSummary,
    builds: BuildsSummary? = nil
  ) {
    self.daemon = daemon
    self.host = host
    self.capacity = capacity
    self.github = github
    self.images = images
    self.profiles = profiles
    self.reconciliation = reconciliation
    self.diskPressure = diskPressure
    self.builds = builds
  }
}

/// In-daemon image builds that have not reached a terminal state (spec P6). `queued` mirrors
/// `ImageBuildState.queued`; `running` is every non-terminal state past it (`resolving` through
/// `sealing`) -- the states in which a build VM is expected to exist.
public struct BuildsSummary: Codable, Sendable, Hashable {
  public var running: Int
  public var queued: Int

  public init(running: Int = 0, queued: Int = 0) {
    self.running = running
    self.queued = queued
  }
}

/// `DiskPressureState` raw value plus the measurement it was computed from (spec §17).
public struct DiskPressureSummary: Codable, Sendable, Hashable {
  public var freeBytes: UInt64
  public var floorBytes: UInt64
  /// `ok`, `warning` or `critical`.
  public var state: String

  public init(freeBytes: UInt64, floorBytes: UInt64, state: String) {
    self.freeBytes = freeBytes
    self.floorBytes = floorBytes
    self.state = state
  }
}

public struct DaemonHealth: Codable, Sendable, Hashable {
  public enum State: String, Codable, Sendable, CaseIterable, Hashable {
    case healthy
    case degraded
  }

  public var state: State
  public var version: String
  public var pid: Int32
  public var hostId: String
  /// `HostMode` raw value.
  public var mode: String
  public var startedAt: String
  public var uptimeSeconds: Int64
  /// Runner sessions that have not reached a terminal state. What `draining` is waiting on.
  public var activeSessions: Int

  public init(
    state: State, version: String, pid: Int32, hostId: String, mode: String, startedAt: String,
    uptimeSeconds: Int64, activeSessions: Int = 0
  ) {
    self.state = state
    self.version = version
    self.pid = pid
    self.hostId = hostId
    self.mode = mode
    self.startedAt = startedAt
    self.uptimeSeconds = uptimeSeconds
    self.activeSessions = activeSessions
  }
}

/// Facts obtained from `vmworker probe`. `probeSucceeded == false` means the values below came
/// from a `ProcessInfo` fallback and no Virtualization limit is authoritative.
public struct HostSummary: Codable, Sendable, Hashable {
  public var osVersion: String
  public var architecture: String
  public var logicalCPUCount: Int
  public var physicalMemoryBytes: UInt64
  public var freeDiskBytes: UInt64
  public var virtualizationSupported: Bool
  public var nestedVirtualizationSupported: Bool
  public var macOSGuestLimit: Int
  public var probeSucceeded: Bool
  public var probeError: String?

  public init(
    osVersion: String, architecture: String, logicalCPUCount: Int, physicalMemoryBytes: UInt64,
    freeDiskBytes: UInt64, virtualizationSupported: Bool, nestedVirtualizationSupported: Bool,
    macOSGuestLimit: Int, probeSucceeded: Bool, probeError: String? = nil
  ) {
    self.osVersion = osVersion
    self.architecture = architecture
    self.logicalCPUCount = logicalCPUCount
    self.physicalMemoryBytes = physicalMemoryBytes
    self.freeDiskBytes = freeDiskBytes
    self.virtualizationSupported = virtualizationSupported
    self.nestedVirtualizationSupported = nestedVirtualizationSupported
    self.macOSGuestLimit = macOSGuestLimit
    self.probeSucceeded = probeSucceeded
    self.probeError = probeError
  }
}

/// `placeholder == true` while a field is still a stand-in; from M2 the counts are real.
public struct CapacitySummary: Codable, Sendable, Hashable {
  public var runningVMs: Int
  public var maxVMs: Int?
  public var reservedCPUCount: Int
  public var reservedMemoryBytes: UInt64
  public var reservedDiskBytes: UInt64
  public var placeholder: Bool

  public init(
    runningVMs: Int, maxVMs: Int?, reservedCPUCount: Int, reservedMemoryBytes: UInt64,
    reservedDiskBytes: UInt64, placeholder: Bool
  ) {
    self.runningVMs = runningVMs
    self.maxVMs = maxVMs
    self.reservedCPUCount = reservedCPUCount
    self.reservedMemoryBytes = reservedMemoryBytes
    self.reservedDiskBytes = reservedDiskBytes
    self.placeholder = placeholder
  }
}

public struct GitHubSummary: Codable, Sendable, Hashable {
  /// `AuthStatus.state`, refreshed by the maintenance loop rather than by this call: `status`
  /// must never depend on api.github.com being reachable.
  public var authState: String
  /// Login behind the credential, when the last probe resolved one.
  public var authLogin: String?
  public var scopeCount: Int
  /// Scopes whose persisted `health` is `healthy`.
  public var scopesHealthy: Int
  public var scaleSetsHealthy: Int
  public var placeholder: Bool

  public init(
    authState: String, authLogin: String? = nil, scopeCount: Int, scopesHealthy: Int = 0,
    scaleSetsHealthy: Int, placeholder: Bool
  ) {
    self.authState = authState
    self.authLogin = authLogin
    self.scopeCount = scopeCount
    self.scopesHealthy = scopesHealthy
    self.scaleSetsHealthy = scaleSetsHealthy
    self.placeholder = placeholder
  }
}

public struct ImageSummary: Codable, Sendable, Hashable {
  public var cached: Int
  public var diskUsageBytes: UInt64
  /// Images whose row is `pulling`: a registry transfer is in flight for them right now.
  public var pulling: Int
  /// Ready images whose baked-in runner is behind the newest release but still inside GitHub's
  /// 30-day update window (spec §53).
  public var runnerStale: Int
  /// Ready images past that window: GitHub itself stops giving such a runner work.
  public var runnerTooOld: Int

  public init(
    cached: Int, diskUsageBytes: UInt64, pulling: Int = 0, runnerStale: Int = 0,
    runnerTooOld: Int = 0
  ) {
    self.cached = cached
    self.diskUsageBytes = diskUsageBytes
    self.pulling = pulling
    self.runnerStale = runnerStale
    self.runnerTooOld = runnerTooOld
  }
}

public struct ProfileRuntimeSummary: Codable, Sendable, Hashable {
  public var name: String
  public var enabled: Bool
  public var busy: Int
  public var idle: Int
  /// `assignedJobs` from the demand provider — what GitHub says is waiting for this profile.
  public var demand: Int
  /// Instances between `planned` and `waitingForAgent`: capacity paid for but not yet usable.
  public var starting: Int

  public init(
    name: String, enabled: Bool, busy: Int, idle: Int, demand: Int = 0, starting: Int = 0
  ) {
    self.name = name
    self.enabled = enabled
    self.busy = busy
    self.idle = idle
    self.demand = demand
    self.starting = starting
  }
}

public struct ReconciliationSummary: Codable, Sendable, Hashable {
  public var lastRunAt: String?
  public var secondsSinceLastRun: Int64?
  public var runCount: Int
  public var errorCount: Int
  public var lastError: String?
  /// Counts observed by the last sweep.
  public var instanceCount: Int
  public var workerCount: Int
  public var orphanCount: Int

  public init(
    lastRunAt: String? = nil, secondsSinceLastRun: Int64? = nil, runCount: Int = 0,
    errorCount: Int = 0, lastError: String? = nil, instanceCount: Int = 0, workerCount: Int = 0,
    orphanCount: Int = 0
  ) {
    self.lastRunAt = lastRunAt
    self.secondsSinceLastRun = secondsSinceLastRun
    self.runCount = runCount
    self.errorCount = errorCount
    self.lastError = lastError
    self.instanceCount = instanceCount
    self.workerCount = workerCount
    self.orphanCount = orphanCount
  }
}

/// `system.version` response.
public struct VersionInfo: Codable, Sendable, Hashable {
  public var version: String
  public var protocolName: String
  public var protocolVersion: Int
  public var schemaVersion: Int

  public init(version: String, protocolName: String, protocolVersion: Int, schemaVersion: Int) {
    self.version = version
    self.protocolName = protocolName
    self.protocolVersion = protocolVersion
    self.schemaVersion = schemaVersion
  }
}

/// `system.drain` (spec §108, §109). `wait` blocks until the last active session ends or
/// `timeoutMs` elapses; the default returns as soon as the mode has moved.
public struct SystemDrainRequest: Codable, Sendable, Hashable {
  public var wait: Bool
  public var timeoutMs: Int64

  public init(wait: Bool = false, timeoutMs: Int64 = 900_000) {
    self.wait = wait
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    wait = try container.decodeIfPresent(Bool.self, forKey: .wait) ?? false
    timeoutMs = try container.decodeIfPresent(Int64.self, forKey: .timeoutMs) ?? 900_000
  }
}

/// What `system.drain`, `system.resume` and `system.offline` all answer with.
public struct SystemModeResponse: Codable, Sendable, Hashable {
  /// `HostMode` raw value.
  public var mode: String
  /// Runner sessions that have not reached a terminal state yet.
  public var activeSessions: Int
  /// False when `wait` was asked for and the timeout fired first.
  public var drained: Bool

  public init(mode: String, activeSessions: Int, drained: Bool) {
    self.mode = mode
    self.activeSessions = activeSessions
    self.drained = drained
  }
}

/// `system.shutdown`. Without `force` the daemon drains first and refuses to stop while a job is
/// still running; `force` stops immediately and leaves the reconciler to sort it out on restart.
public struct SystemShutdownRequest: Codable, Sendable, Hashable {
  public var force: Bool
  public var timeoutMs: Int64

  public init(force: Bool = false, timeoutMs: Int64 = 900_000) {
    self.force = force
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    timeoutMs = try container.decodeIfPresent(Int64.self, forKey: .timeoutMs) ?? 900_000
  }
}

public struct SystemShutdownResponse: Codable, Sendable, Hashable {
  /// True when the daemon accepted the request and is now shutting down.
  public var accepted: Bool
  public var mode: String
  public var activeSessions: Int

  public init(accepted: Bool, mode: String, activeSessions: Int) {
    self.accepted = accepted
    self.mode = mode
    self.activeSessions = activeSessions
  }
}
