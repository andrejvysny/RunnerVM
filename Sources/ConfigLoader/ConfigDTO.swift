import RunnerCore

/// Decodable mirror of the YAML configuration document (spec §63, §91: "YAML -> ConfigDTO ->
/// validation -> RunnerConfiguration"). Every field is optional except `version`: RunnerCore's own
/// models already apply a per-field default when a key is absent, but a configuration *file* is
/// expected to pin its version explicitly, so `ConfigLoader` enforces that one field itself.
///
/// Leaf types (`ByteSize`, `DurationValue`, `GuestOS`, `InstanceLifecycle`, `GitHubScopeKind`,
/// `HostConfig.MaxVMs`, `GitHubAuthConfig.Provider/.Source`, `DemandMode`) are reused directly from
/// RunnerCore rather than re-parsed here, so string parsing and enum spelling live in exactly one
/// place.
struct ConfigDTO: Decodable {
  struct Host: Decodable {
    struct Reserve: Decodable {
      var cpu: Int?
      var memory: ByteSize?
      var disk: ByteSize?
    }

    struct Overcommit: Decodable {
      var cpu: Double?
      var memory: Double?
      var disk: Double?
    }

    struct Limits: Decodable {
      var concurrentImagePulls: Int?
      var concurrentVMStarts: Int?
    }

    var reserve: Reserve?
    var overcommit: Overcommit?
    var maxVMs: HostConfig.MaxVMs?
    var limits: Limits?
  }

  struct GitHub: Decodable {
    struct Auth: Decodable {
      var provider: GitHubAuthConfig.Provider?
      var source: GitHubAuthConfig.Source?
    }

    struct Scope: Decodable {
      var name: String?
      var type: GitHubScopeKind?
      var owner: String?
      var repository: String?
      var runnerGroup: String?
    }

    var auth: Auth?
    var scopes: [Scope]?
    var demand: DemandMode?
  }

  struct Profile: Decodable {
    struct Resources: Decodable {
      var cpu: Int?
      var memory: ByteSize?
      var disk: ByteSize?
    }

    struct WarmPool: Decodable {
      var minIdle: Int?
      var maxIdle: Int?
      var idleTTL: DurationValue?
    }

    struct Limits: Decodable {
      var maxInstances: Int?
    }

    struct SSH: Decodable {
      var enabled: Bool?
    }

    struct Reuse: Decodable {
      var maxJobs: Int?
      var maxAge: DurationValue?
      var recycleOnFailure: Bool?
      var maxRestarts: Int?
      var acknowledgeSharedHost: Bool?
    }

    struct Timeouts: Decodable {
      var vmBoot: DurationValue?
      var agentReady: DurationValue?
      var runnerOnline: DurationValue?
      var gracefulShutdown: DurationValue?
      var imagePull: DurationValue?
      var clone: DurationValue?
      var jitGeneration: DurationValue?
      var jobMaxRuntime: DurationValue?
      var cleanup: DurationValue?
    }

    var name: String?
    var scope: String?
    var image: String?
    var os: GuestOS?
    var lifecycle: InstanceLifecycle?
    var resources: Resources?
    var warmPool: WarmPool?
    var limits: Limits?
    var ssh: SSH?
    var reuse: Reuse?
    var timeouts: Timeouts?
    var allowHostedLabelShadowing: Bool?
  }

  struct Security: Decodable {
    var allowPublicRepositories: Bool?
  }

  struct Metrics: Decodable {
    struct Prometheus: Decodable {
      var enabled: Bool?
      var listen: String?
    }

    var prometheus: Prometheus?
  }

  struct Diagnostics: Decodable {
    var failedInstanceRetention: DurationValue?
  }

  struct Images: Decodable {
    struct Cache: Decodable {
      var maxSize: ByteSize?
      var keepRecentlyUsed: DurationValue?
    }

    struct Limits: Decodable {
      var maxVirtualDiskSize: ByteSize?
      var maxLayers: Int?
    }

    struct Updates: Decodable {
      var enabled: Bool?
      var interval: DurationValue?
      var jitter: DurationValue?
      var keepPrevious: Int?
      var smokeTest: Bool?
    }

    /// `kind` stays a `String` here rather than `ManagedImageKind`: the YAML spelling is
    /// hyphenated (`macos-tart`) while the enum's raw value is the camelCase form the
    /// `managed_images.kind` column stores. `ConfigMapper` is where the two meet.
    struct Managed: Decodable {
      struct Resources: Decodable {
        var cpu: Int?
        var memory: ByteSize?
      }

      var name: String?
      var kind: String?
      var source: String?
      var autoUpdate: Bool?
      var resources: Resources?
    }

    var cache: Cache?
    var limits: Limits?
    var prefetch: Bool?
    var updates: Updates?
    var managed: [Managed]?
  }

  struct ImageUpdates: Decodable {
    var recycleReusable: Bool?
    var denyTooOldRunner: Bool?
  }

  struct Build: Decodable {
    /// Base-image cache bounds. Separate from `images.cache`, which is the image store's policy.
    struct Cache: Decodable {
      var maxBytes: ByteSize?
      var minimumHostFreeBytes: ByteSize?
      var maxEntries: Int?
    }

    var cpu: Int?
    var memory: ByteSize?
    var disk: ByteSize?
    var timeout: DurationValue?
    var stepTimeout: DurationValue?
    var maxConcurrent: Int?
    var cacheDir: String?
    var guestAgentPath: String?
    var macosGuestAgentPath: String?
    var macosProvisionScript: String?
    var recipeFileName: String?
    var maxContextSize: ByteSize?
    var maxLogSize: ByteSize?
    var maxSteps: Int?
    var cache: Cache?
  }

  struct Logging: Decodable {
    struct File: Decodable {
      var enabled: Bool?
      var maxSize: ByteSize?
      var maxFiles: Int?
    }

    struct Retention: Decodable {
      var instanceLogs: DurationValue?
    }

    var file: File?
    var retention: Retention?
    var collectRunnerDiagnostics: Bool?
    var diagnosticsTimeout: DurationValue?
  }

  var version: Int
  var host: Host?
  var github: GitHub?
  var profiles: [Profile]?
  var security: Security?
  var metrics: Metrics?
  var diagnostics: Diagnostics?
  var images: Images?
  var imageUpdates: ImageUpdates?
  var logging: Logging?
  var build: Build?
}
