import Foundation

/// `instances.purpose` (`docs/db_schema_v4.sql`). A `maintenance` instance qualifies a candidate
/// managed image rather than running a job, so the scheduler and demand accounting exclude it.
public enum InstancePurpose: String, Codable, Sendable, CaseIterable, Hashable {
  case runner
  case maintenance
}

/// `image_builds.kind` (`docs/db_schema_v4.sql`). Distinguishes a macOS guest-provisioning build
/// from an ordinary Runnerfile build.
public enum ImageBuildKind: String, Codable, Sendable, CaseIterable, Hashable {
  case runnerfile
  case macosProvision
}

/// `managed_images.kind` (`docs/db_schema_v4.sql`): the kind of upstream source a managed image
/// tracks -- a container registry tag, or a Tart macOS image.
public enum ManagedImageKind: String, Codable, Sendable, CaseIterable, Hashable {
  case registryTag
  case macosTart
}

/// `images.updates` (spec: `docs/design/distribution.md`, "Update invariants"). Cadence and
/// retention for the image update service.
///
/// Configuration surface only in this phase: nothing reads these fields yet -- `ImageUpdateService`
/// (phase D6) is what will. They exist now so a document written by `runnerctl setup` already has
/// its final shape and does not need rewriting when the service lands.
public struct ImageUpdatePolicyConfig: Codable, Sendable, Hashable {
  /// Below this a check is pure registry traffic with no chance of an upstream having moved.
  public static let minimumInterval = DurationValue.minutes(15)
  /// Each retained digest is a whole image on disk; more than a handful is a storage leak with a
  /// configuration key in front of it.
  public static let maximumKeepPrevious = 5

  public var enabled: Bool
  /// How often each tracked source is re-resolved.
  public var interval: DurationValue
  /// Spread applied to `interval` so a fleet installed from one script does not check in lockstep.
  public var jitter: DurationValue
  /// How many superseded digests survive a promotion. The **only** deletion trigger: digests past
  /// this count are deleted when `ImageManager`'s prune eligibility also agrees.
  public var keepPrevious: Int
  /// Qualify a candidate with the shared smoke test before promoting it.
  public var smokeTest: Bool

  public init(
    enabled: Bool = false,
    interval: DurationValue = .hours(6),
    jitter: DurationValue = .minutes(30),
    keepPrevious: Int = 1,
    smokeTest: Bool = true
  ) {
    self.enabled = enabled
    self.interval = interval
    self.jitter = jitter
    self.keepPrevious = keepPrevious
    self.smokeTest = smokeTest
  }
}

extension ImageUpdatePolicyConfig {
  private enum CodingKeys: String, CodingKey {
    case enabled, interval, jitter, keepPrevious, smokeTest
  }

  /// Per-key leniency, like `HostConfig.Overcommit`: a document persisted before any one of these
  /// fields existed still decodes, with the missing key meaning its default.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ImageUpdatePolicyConfig()
    self.init(
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
      interval: try c.decodeIfPresent(DurationValue.self, forKey: .interval) ?? d.interval,
      jitter: try c.decodeIfPresent(DurationValue.self, forKey: .jitter) ?? d.jitter,
      keepPrevious: try c.decodeIfPresent(Int.self, forKey: .keepPrevious) ?? d.keepPrevious,
      smokeTest: try c.decodeIfPresent(Bool.self, forKey: .smokeTest) ?? d.smokeTest
    )
  }
}

/// One `images.managed[]` entry: an upstream source RunnerVM keeps up to date on the host's own
/// behalf, promoted to a local alias only after a build -> qualify run succeeds
/// (`docs/design/distribution.md`, "Managed image sources").
///
/// Distinct from a profile pointing straight at a registry image: a `macos-tart` source is not
/// runnable as pulled (a Tart export carries no RunnerVM guest agent), so it becomes a profile
/// image only through a local provisioning run that publishes under `name`.
///
/// Configuration surface only in this phase; phases D6/D7 are what will read it.
public struct ManagedImageSourceConfig: Codable, Sendable, Hashable {
  /// Sizing for the provisioning/builder VM this source is materialized in -- not for the runner
  /// instances that later boot the promoted image, which take their profile's `resources`.
  public struct Resources: Codable, Sendable, Hashable {
    public var cpuCount: Int
    public var memoryBytes: UInt64

    public init(cpuCount: Int = 4, memoryBytes: UInt64 = ByteSize.gibibytes(8).bytes) {
      self.cpuCount = cpuCount
      self.memoryBytes = memoryBytes
    }
  }

  /// The local alias the qualified digest is promoted to; a macOS profile names this in `image`.
  public var name: String
  public var kind: ManagedImageKind
  /// The upstream reference, e.g. `ghcr.io/cirruslabs/macos-tahoe-base:latest`.
  public var source: String
  public var autoUpdate: Bool
  /// `nil` means "use the kind's defaults" rather than "no resources".
  public var resources: Resources?

  public init(
    name: String, kind: ManagedImageKind, source: String, autoUpdate: Bool = true,
    resources: Resources? = nil
  ) {
    self.name = name
    self.kind = kind
    self.source = source
    self.autoUpdate = autoUpdate
    self.resources = resources
  }
}

extension ManagedImageSourceConfig {
  private enum CodingKeys: String, CodingKey {
    case name, kind, source, autoUpdate, resources
  }

  /// `name`/`kind`/`source` identify the entry and have no meaningful default; the rest are
  /// lenient so a row persisted before they existed still decodes.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try c.decode(String.self, forKey: .name),
      kind: try c.decode(ManagedImageKind.self, forKey: .kind),
      source: try c.decode(String.self, forKey: .source),
      autoUpdate: try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true,
      resources: try c.decodeIfPresent(Resources.self, forKey: .resources)
    )
  }
}
