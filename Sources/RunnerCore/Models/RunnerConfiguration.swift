import Foundation

/// Credential provider selection (spec §12). The credential itself never lives in the config file.
public struct GitHubAuthConfig: Codable, Sendable, Hashable {
  public enum Provider: String, Codable, Sendable, CaseIterable { case pat, app }
  public enum Source: String, Codable, Sendable, CaseIterable { case keychain, env, file }

  public var provider: Provider
  public var source: Source

  public init(provider: Provider = .pat, source: Source = .keychain) {
    self.provider = provider
    self.source = source
  }
}

/// Which demand provider drives the orchestrator (spec §13, §118). `scaleSet` talks to GitHub's
/// own scale-set statistics; `manual` accepts `debug.demandSet` instead and is for tests/debugging
/// only.
public enum DemandMode: String, Codable, Sendable, CaseIterable {
  case scaleSet
  case manual
}

public struct GitHubConfig: Codable, Sendable, Hashable {
  public var auth: GitHubAuthConfig
  public var scopes: [GitHubScopeConfig]
  public var demand: DemandMode

  public init(
    auth: GitHubAuthConfig = GitHubAuthConfig(), scopes: [GitHubScopeConfig] = [],
    demand: DemandMode = .scaleSet
  ) {
    self.auth = auth
    self.scopes = scopes
    self.demand = demand
  }
}

extension GitHubConfig {
  private enum CodingKeys: String, CodingKey {
    case auth, scopes, demand
  }

  /// `demand` defaults so a document persisted before this field existed still decodes (spec
  /// §63/§91 back-compat).
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      auth: try c.decode(GitHubAuthConfig.self, forKey: .auth),
      scopes: try c.decode([GitHubScopeConfig].self, forKey: .scopes),
      demand: try c.decodeIfPresent(DemandMode.self, forKey: .demand) ?? .scaleSet
    )
  }
}

/// Spec §77: public pull-request workloads on a self-hosted runner are off by default.
public struct SecurityConfig: Codable, Sendable, Hashable {
  public var allowPublicRepositories: Bool

  public init(allowPublicRepositories: Bool = false) {
    self.allowPublicRepositories = allowPublicRepositories
  }
}

public struct MetricsConfig: Codable, Sendable, Hashable {
  public struct Prometheus: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// `host:port`. Loopback by default; RunnerVM never exposes metrics off-host (spec §43).
    public var listen: String

    public init(enabled: Bool = false, listen: String = "127.0.0.1:9095") {
      self.enabled = enabled
      self.listen = listen
    }
  }

  public var prometheus: Prometheus

  public init(prometheus: Prometheus = Prometheus()) {
    self.prometheus = prometheus
  }
}

/// How long a failed instance directory survives for post-mortem (spec §74).
public struct DiagnosticsConfig: Codable, Sendable, Hashable {
  public var failedInstanceRetention: DurationValue

  public init(failedInstanceRetention: DurationValue = .hours(2)) {
    self.failedInstanceRetention = failedInstanceRetention
  }
}

/// Local image-store safety ceilings (Phase 4/5 image builder), independent of `ImageCacheConfig`'s
/// eviction policy: these bound what a single image/build may occupy, not what long-term caching
/// keeps around.
public struct ImageLimitsConfig: Codable, Sendable, Hashable {
  public var maxVirtualDiskBytes: UInt64
  public var maxLayers: Int

  public init(maxVirtualDiskBytes: UInt64 = ByteSize.gibibytes(512).bytes, maxLayers: Int = 4_096) {
    self.maxVirtualDiskBytes = maxVirtualDiskBytes
    self.maxLayers = maxLayers
  }
}

/// Image cache policy (spec §110).
public struct ImageCacheConfig: Codable, Sendable, Hashable {
  /// `nil` means "bounded only by the host disk reserve".
  public var maxSizeBytes: UInt64?
  /// Grace window in which an unreferenced image is kept anyway.
  public var keepRecentlyUsed: DurationValue
  public var limits: ImageLimitsConfig
  /// Pull every enabled profile's registry image as soon as the configuration is applied, instead
  /// of leaving the transfer to the first `instance.create` that needs it.
  ///
  /// Off by default: it turns `config apply` and daemon start into operations that reach the
  /// network. Worth turning on wherever profiles point at a registry rather than a local build,
  /// because otherwise the first job after a config change waits for the whole image and looks
  /// like a runner failure rather than a download.
  public var prefetch: Bool
  /// Cadence and retention for the image update service (phase D6). Configuration surface only:
  /// nothing reads this yet.
  public var updates: ImageUpdatePolicyConfig
  /// Upstream sources RunnerVM keeps up to date on the host's own behalf (phases D6/D7).
  /// Configuration surface only: nothing reads this yet.
  public var managed: [ManagedImageSourceConfig]

  public init(
    maxSizeBytes: UInt64? = nil, keepRecentlyUsed: DurationValue = .days(7),
    limits: ImageLimitsConfig = ImageLimitsConfig(), prefetch: Bool = false,
    updates: ImageUpdatePolicyConfig = ImageUpdatePolicyConfig(),
    managed: [ManagedImageSourceConfig] = []
  ) {
    self.maxSizeBytes = maxSizeBytes
    self.keepRecentlyUsed = keepRecentlyUsed
    self.prefetch = prefetch
    self.limits = limits
    self.updates = updates
    self.managed = managed
  }
}

extension ImageCacheConfig {
  private enum CodingKeys: String, CodingKey {
    case maxSizeBytes, keepRecentlyUsed, limits, prefetch, updates, managed
  }

  /// Per-key leniency, like `HostConfig`: `updates`/`managed` are newer than the rest of the
  /// block, so a configuration persisted before they existed still decodes and means "no managed
  /// sources, updates off".
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ImageCacheConfig()
    self.init(
      maxSizeBytes: try c.decodeIfPresent(UInt64.self, forKey: .maxSizeBytes),
      keepRecentlyUsed: try c.decodeIfPresent(DurationValue.self, forKey: .keepRecentlyUsed)
        ?? d.keepRecentlyUsed,
      limits: try c.decodeIfPresent(ImageLimitsConfig.self, forKey: .limits) ?? d.limits,
      prefetch: try c.decodeIfPresent(Bool.self, forKey: .prefetch) ?? d.prefetch,
      updates: try c.decodeIfPresent(ImageUpdatePolicyConfig.self, forKey: .updates) ?? d.updates,
      managed: try c.decodeIfPresent([ManagedImageSourceConfig].self, forKey: .managed) ?? d.managed
    )
  }
}

/// Whether a reusable instance still on a superseded image digest is retired (spec §138), and
/// how far behind the baked-in `actions/runner` may fall before an image stops being schedulable
/// (spec §53).
public struct ImageUpdatesConfig: Codable, Sendable, Hashable {
  public var recycleReusable: Bool
  /// `true` refuses `vm create` from an image whose runner is `tooOld` — past GitHub's 30-day
  /// update window — instead of only warning about it. Off by default: a fleet with no GitHub
  /// credential can never grade its images, and blocking on `unknown`-adjacent data would park
  /// every profile on the host.
  public var denyTooOldRunner: Bool

  public init(recycleReusable: Bool = true, denyTooOldRunner: Bool = false) {
    self.recycleReusable = recycleReusable
    self.denyTooOldRunner = denyTooOldRunner
  }
}

/// Root of the validated in-memory configuration (spec §63). YAML decoding lives in ConfigLoader.
public struct RunnerConfiguration: Codable, Sendable, Hashable {
  public static let currentVersion = 1

  public var version: Int
  public var host: HostConfig
  public var github: GitHubConfig
  public var profiles: [RunnerProfileConfig]
  public var security: SecurityConfig
  public var metrics: MetricsConfig
  public var diagnostics: DiagnosticsConfig
  public var images: ImageCacheConfig
  public var imageUpdates: ImageUpdatesConfig
  public var logging: LoggingConfig
  public var build: ImageBuildConfig

  public init(
    version: Int = RunnerConfiguration.currentVersion,
    host: HostConfig = HostConfig(),
    github: GitHubConfig = GitHubConfig(),
    profiles: [RunnerProfileConfig] = [],
    security: SecurityConfig = SecurityConfig(),
    metrics: MetricsConfig = MetricsConfig(),
    diagnostics: DiagnosticsConfig = DiagnosticsConfig(),
    images: ImageCacheConfig = ImageCacheConfig(),
    imageUpdates: ImageUpdatesConfig = ImageUpdatesConfig(),
    logging: LoggingConfig = LoggingConfig(),
    build: ImageBuildConfig = ImageBuildConfig()
  ) {
    self.version = version
    self.host = host
    self.github = github
    self.profiles = profiles
    self.security = security
    self.metrics = metrics
    self.diagnostics = diagnostics
    self.images = images
    self.imageUpdates = imageUpdates
    self.logging = logging
    self.build = build
  }

  public func profile(named name: String) -> RunnerProfileConfig? {
    profiles.first { $0.name == name }
  }

  public func scope(named name: String) -> GitHubScopeConfig? {
    github.scopes.first { $0.name == name }
  }
}

extension RunnerConfiguration {
  private enum CodingKeys: String, CodingKey {
    case version, host, github, profiles, security, metrics, diagnostics, images, imageUpdates
    case logging, build
  }

  /// Every section except `version` defaults, so a minimal document decodes and validation — not
  /// the decoder — reports what is actually wrong.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
      host: try c.decodeIfPresent(HostConfig.self, forKey: .host) ?? HostConfig(),
      github: try c.decodeIfPresent(GitHubConfig.self, forKey: .github) ?? GitHubConfig(),
      profiles: try c.decodeIfPresent([RunnerProfileConfig].self, forKey: .profiles) ?? [],
      security: try c.decodeIfPresent(SecurityConfig.self, forKey: .security) ?? SecurityConfig(),
      metrics: try c.decodeIfPresent(MetricsConfig.self, forKey: .metrics) ?? MetricsConfig(),
      diagnostics: try c.decodeIfPresent(DiagnosticsConfig.self, forKey: .diagnostics)
        ?? DiagnosticsConfig(),
      images: try c.decodeIfPresent(ImageCacheConfig.self, forKey: .images) ?? ImageCacheConfig(),
      // `imageUpdates` defaults so a document persisted before this field existed still decodes
      // (spec §138 back-compat).
      imageUpdates: try c.decodeIfPresent(ImageUpdatesConfig.self, forKey: .imageUpdates)
        ?? ImageUpdatesConfig(),
      // Same back-compat rule: a document written before log durability existed still loads.
      logging: try c.decodeIfPresent(LoggingConfig.self, forKey: .logging) ?? LoggingConfig(),
      // Same back-compat rule: a document written before the in-daemon image builder existed
      // still loads (Phase 4/5).
      build: try c.decodeIfPresent(ImageBuildConfig.self, forKey: .build) ?? ImageBuildConfig()
    )
  }
}
