import Foundation

public enum InstanceLifecycle: String, Codable, Sendable, CaseIterable, Hashable {
  /// One job, then destroy. The default (spec §65).
  case ephemeral
  /// Cleaned and returned to `idle` between jobs, bounded by `ReusePolicy`.
  case reusable
}

/// Resolved per-instance allocation. v1 stores explicit values; `cpu: auto` is future work (§124).
public struct ResourceSpec: Codable, Sendable, Hashable {
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64

  public init(cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64) {
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
  }

  /// Spec §124 baseline sizing.
  public static func defaults(for guestOS: GuestOS) -> ResourceSpec {
    switch guestOS {
    case .linux:
      ResourceSpec(
        cpuCount: 4,
        memoryBytes: ByteSize.gibibytes(8).bytes,
        diskBytes: ByteSize.gibibytes(80).bytes
      )
    case .macos:
      ResourceSpec(
        cpuCount: 6,
        memoryBytes: ByteSize.gibibytes(12).bytes,
        diskBytes: ByteSize.gibibytes(120).bytes
      )
    }
  }
}

/// Idle VMs hold their full memory reservation, so `minIdle` participates in capacity math (§127).
public struct WarmPoolPolicy: Codable, Sendable, Hashable {
  public var minIdle: Int
  public var maxIdle: Int
  public var idleTTL: DurationValue

  public init(minIdle: Int = 0, maxIdle: Int = 0, idleTTL: DurationValue = .minutes(20)) {
    self.minIdle = minIdle
    self.maxIdle = maxIdle
    self.idleTTL = idleTTL
  }

  public static let disabled = WarmPoolPolicy()
}

/// Bounds on reuse (spec §126). Exceeding either bound retires the instance instead of recycling it.
public struct ReusePolicy: Codable, Sendable, Hashable {
  public var maxJobs: Int
  public var maxAge: DurationValue
  public var recycleOnFailure: Bool
  /// Spec §72: how many times an idle/cleaning reusable VM whose worker died may be restarted
  /// from its own disk before it is recycled instead.
  public var maxRestarts: Int

  public init(
    maxJobs: Int = 10, maxAge: DurationValue = .hours(4), recycleOnFailure: Bool = true,
    maxRestarts: Int = 1
  ) {
    self.maxJobs = maxJobs
    self.maxAge = maxAge
    self.recycleOnFailure = recycleOnFailure
    self.maxRestarts = maxRestarts
  }

  public static let `default` = ReusePolicy()
}

extension ReusePolicy {
  private enum CodingKeys: String, CodingKey {
    case maxJobs, maxAge, recycleOnFailure, maxRestarts
  }

  /// `maxRestarts` defaults so a `runner_profiles.config_json` row written before this field
  /// existed still decodes (spec §72 back-compat).
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxJobs: try c.decode(Int.self, forKey: .maxJobs),
      maxAge: try c.decode(DurationValue.self, forKey: .maxAge),
      recycleOnFailure: try c.decode(Bool.self, forKey: .recycleOnFailure),
      maxRestarts: try c.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 1
    )
  }
}

/// Per-stage deadlines (spec §73). Expiry becomes a typed failure and triggers reconciliation.
public struct TimeoutPolicy: Codable, Sendable, Hashable {
  public var imagePull: DurationValue
  public var clone: DurationValue
  public var vmBoot: DurationValue
  public var agentReady: DurationValue
  public var jitGeneration: DurationValue
  public var runnerOnline: DurationValue
  public var jobMaxRuntime: DurationValue
  public var gracefulShutdown: DurationValue
  public var cleanup: DurationValue

  public init(
    imagePull: DurationValue = .minutes(30),
    clone: DurationValue = .minutes(10),
    vmBoot: DurationValue = .minutes(3),
    agentReady: DurationValue = .minutes(2),
    jitGeneration: DurationValue = .seconds(30),
    runnerOnline: DurationValue = .minutes(2),
    jobMaxRuntime: DurationValue = .hours(6),
    gracefulShutdown: DurationValue = .seconds(30),
    cleanup: DurationValue = .minutes(5)
  ) {
    self.imagePull = imagePull
    self.clone = clone
    self.vmBoot = vmBoot
    self.agentReady = agentReady
    self.jitGeneration = jitGeneration
    self.runnerOnline = runnerOnline
    self.jobMaxRuntime = jobMaxRuntime
    self.gracefulShutdown = gracefulShutdown
    self.cleanup = cleanup
  }

  public static let `default` = TimeoutPolicy()

  public var all: [(name: String, value: DurationValue)] {
    [
      ("imagePull", imagePull), ("clone", clone), ("vmBoot", vmBoot), ("agentReady", agentReady),
      ("jitGeneration", jitGeneration), ("runnerOnline", runnerOnline),
      ("jobMaxRuntime", jobMaxRuntime), ("gracefulShutdown", gracefulShutdown), ("cleanup", cleanup),
    ]
  }
}

public struct SSHPolicy: Codable, Sendable, Hashable {
  public var enabled: Bool

  public init(enabled: Bool = true) {
    self.enabled = enabled
  }
}

public struct ProfileLimits: Codable, Sendable, Hashable {
  /// `nil` means "bounded only by host capacity".
  public var maxInstances: Int?

  public init(maxInstances: Int? = nil) {
    self.maxInstances = maxInstances
  }
}

/// The primary scheduling/configuration unit (spec §10).
public struct RunnerProfileConfig: Codable, Sendable, Hashable {
  public var name: String
  /// `GitHubScopeConfig.name` this profile registers under.
  public var scope: String
  /// Image reference string; validated with `ImageReference` rather than stored parsed, because a
  /// profile keeps its literal tag while instances pin the resolved digest (spec §138).
  public var image: String
  public var guestOS: GuestOS
  public var lifecycle: InstanceLifecycle
  public var resources: ResourceSpec
  public var warmPool: WarmPoolPolicy
  public var limits: ProfileLimits
  public var ssh: SSHPolicy
  /// Only meaningful when `lifecycle == .reusable`.
  public var reuse: ReusePolicy?
  /// `nil` inherits `TimeoutPolicy.default`.
  public var timeouts: TimeoutPolicy?

  public init(
    name: String,
    scope: String,
    image: String,
    guestOS: GuestOS,
    lifecycle: InstanceLifecycle = .ephemeral,
    resources: ResourceSpec? = nil,
    warmPool: WarmPoolPolicy = .disabled,
    limits: ProfileLimits = ProfileLimits(),
    ssh: SSHPolicy = SSHPolicy(),
    reuse: ReusePolicy? = nil,
    timeouts: TimeoutPolicy? = nil
  ) {
    self.name = name
    self.scope = scope
    self.image = image
    self.guestOS = guestOS
    self.lifecycle = lifecycle
    self.resources = resources ?? .defaults(for: guestOS)
    self.warmPool = warmPool
    self.limits = limits
    self.ssh = ssh
    self.reuse = reuse
    self.timeouts = timeouts
  }

  public var effectiveTimeouts: TimeoutPolicy { timeouts ?? .default }

  public var effectiveReuse: ReusePolicy? { lifecycle == .reusable ? (reuse ?? .default) : nil }

  /// `rvm-<profile-short>-<short-uuid>` needs a filesystem- and DNS-safe stem (spec §125).
  public var shortName: String {
    String(name.filter { $0.isLetter || $0.isNumber }.lowercased().prefix(12))
  }
}

extension RunnerProfileConfig {
  private enum CodingKeys: String, CodingKey {
    case name, scope, image, guestOS, lifecycle, resources, warmPool, limits, ssh, reuse, timeouts
  }

  /// Lenient for the optional sections so a `runner_profiles.config_json` written by an older
  /// build still decodes after new sections are added.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
    self.init(
      name: try c.decode(String.self, forKey: .name),
      scope: try c.decode(String.self, forKey: .scope),
      image: try c.decode(String.self, forKey: .image),
      guestOS: guestOS,
      lifecycle: try c.decodeIfPresent(InstanceLifecycle.self, forKey: .lifecycle) ?? .ephemeral,
      resources: try c.decodeIfPresent(ResourceSpec.self, forKey: .resources),
      warmPool: try c.decodeIfPresent(WarmPoolPolicy.self, forKey: .warmPool) ?? .disabled,
      limits: try c.decodeIfPresent(ProfileLimits.self, forKey: .limits) ?? ProfileLimits(),
      ssh: try c.decodeIfPresent(SSHPolicy.self, forKey: .ssh) ?? SSHPolicy(),
      reuse: try c.decodeIfPresent(ReusePolicy.self, forKey: .reuse),
      timeouts: try c.decodeIfPresent(TimeoutPolicy.self, forKey: .timeouts)
    )
  }
}
