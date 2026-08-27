import Foundation

/// Bound on the builder's `FROM cloud-image:` base cache (`<rootDir>/cache/base-images`).
///
/// Deliberately *not* `ImageCacheConfig`: that governs the content-addressed image store and its
/// pin/reference rules, while this bounds a pure download cache whose entries are keyed by the
/// digest a recipe named. Every limit is optional except the host free-space floor -- an unbounded
/// cache that still refuses to fill the disk is a sane default, a cache that can is not.
public struct BaseImageCachePolicy: Codable, Sendable, Hashable {
  /// `nil` leaves the cache unbounded by size; `minimumHostFreeBytes` still applies.
  public var maxBytes: UInt64?
  /// Free space the cache refuses to consume, *on top of* `host.reserve.disk`.
  public var minimumHostFreeBytes: UInt64
  /// `nil` leaves the cache unbounded by entry count.
  public var maxEntries: Int?

  public init(
    maxBytes: UInt64? = nil,
    minimumHostFreeBytes: UInt64 = ByteSize.gibibytes(10).bytes,
    maxEntries: Int? = nil
  ) {
    self.maxBytes = maxBytes
    self.minimumHostFreeBytes = minimumHostFreeBytes
    self.maxEntries = maxEntries
  }
}

extension BaseImageCachePolicy {
  private enum CodingKeys: String, CodingKey {
    case maxBytes, minimumHostFreeBytes, maxEntries
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = BaseImageCachePolicy()
    self.init(
      maxBytes: try c.decodeIfPresent(UInt64.self, forKey: .maxBytes),
      minimumHostFreeBytes: try c.decodeIfPresent(UInt64.self, forKey: .minimumHostFreeBytes)
        ?? d.minimumHostFreeBytes,
      maxEntries: try c.decodeIfPresent(Int.self, forKey: .maxEntries)
    )
  }
}

/// In-daemon image build defaults and limits (Phase 4/5 image builder). Every field decodes
/// leniently per key, so a document persisted before a given field existed still loads (mirrors
/// `ImageUpdatesConfig`).
public struct ImageBuildConfig: Codable, Sendable, Hashable {
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var timeout: DurationValue
  /// The guest agent silently clamps exec timeouts at 30 minutes, so a longer step timeout would
  /// never actually apply -- caught explicitly at validation (`BUILD_STEP_TIMEOUT_TOO_LONG`)
  /// instead of just being quietly ineffective.
  public var stepTimeout: DurationValue
  public var maxConcurrent: Int
  /// `nil` uses `RunnerPaths.baseImageCacheDir`.
  public var cacheDir: String?
  /// `nil` resolves the bundled guest agent at its default location.
  public var guestAgentPath: String?
  public var recipeFileName: String
  public var maxContextBytes: UInt64
  public var maxLogBytes: UInt64
  public var maxSteps: Int
  /// Eviction policy for the `FROM cloud-image:` base cache under `cacheDir`.
  public var cache: BaseImageCachePolicy

  public init(
    cpuCount: Int = 4, memoryBytes: UInt64 = ByteSize.gibibytes(4).bytes,
    diskBytes: UInt64 = ByteSize.gibibytes(16).bytes, timeout: DurationValue = .minutes(60),
    stepTimeout: DurationValue = .minutes(30), maxConcurrent: Int = 1, cacheDir: String? = nil,
    guestAgentPath: String? = nil, recipeFileName: String = "Runnerfile",
    maxContextBytes: UInt64 = ByteSize.gibibytes(1).bytes,
    maxLogBytes: UInt64 = ByteSize.mebibytes(64).bytes, maxSteps: Int = 256,
    cache: BaseImageCachePolicy = BaseImageCachePolicy()
  ) {
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.timeout = timeout
    self.stepTimeout = stepTimeout
    self.maxConcurrent = maxConcurrent
    self.cacheDir = cacheDir
    self.guestAgentPath = guestAgentPath
    self.recipeFileName = recipeFileName
    self.maxContextBytes = maxContextBytes
    self.maxLogBytes = maxLogBytes
    self.maxSteps = maxSteps
    self.cache = cache
  }
}

extension ImageBuildConfig {
  private enum CodingKeys: String, CodingKey {
    case cpuCount, memoryBytes, diskBytes, timeout, stepTimeout, maxConcurrent, cacheDir
    case guestAgentPath, recipeFileName, maxContextBytes, maxLogBytes, maxSteps, cache
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ImageBuildConfig()
    self.init(
      cpuCount: try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? d.cpuCount,
      memoryBytes: try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? d.memoryBytes,
      diskBytes: try c.decodeIfPresent(UInt64.self, forKey: .diskBytes) ?? d.diskBytes,
      timeout: try c.decodeIfPresent(DurationValue.self, forKey: .timeout) ?? d.timeout,
      stepTimeout: try c.decodeIfPresent(DurationValue.self, forKey: .stepTimeout) ?? d.stepTimeout,
      maxConcurrent: try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? d.maxConcurrent,
      cacheDir: try c.decodeIfPresent(String.self, forKey: .cacheDir),
      guestAgentPath: try c.decodeIfPresent(String.self, forKey: .guestAgentPath),
      recipeFileName: try c.decodeIfPresent(String.self, forKey: .recipeFileName) ?? d.recipeFileName,
      maxContextBytes: try c.decodeIfPresent(UInt64.self, forKey: .maxContextBytes) ?? d.maxContextBytes,
      maxLogBytes: try c.decodeIfPresent(UInt64.self, forKey: .maxLogBytes) ?? d.maxLogBytes,
      maxSteps: try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? d.maxSteps,
      cache: try c.decodeIfPresent(BaseImageCachePolicy.self, forKey: .cache) ?? d.cache
    )
  }
}
