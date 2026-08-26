import Foundation

/// How the daemon persists its own observability output (spec §42, §74, §117).
///
/// Everything here is about durability, not verbosity: the log *level* stays a process argument
/// (`--log-level` / `RUNNERVM_LOG_LEVEL`) because it has to take effect before a configuration
/// document has been read.
public struct LoggingConfig: Codable, Sendable, Hashable {
  /// The rotating `logs/runnerd/runnerd.log` and `logs/events.jsonl` files.
  public struct FileConfig: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Size at which the live file becomes `.1`.
    public var maxSizeBytes: UInt64
    /// How many archives (`.1` … `.maxFiles`) survive; the live file is extra.
    public var maxFiles: Int

    public init(
      enabled: Bool = true,
      maxSizeBytes: UInt64 = ByteSize.mebibytes(32).bytes,
      maxFiles: Int = 10
    ) {
      self.enabled = enabled
      self.maxSizeBytes = maxSizeBytes
      self.maxFiles = maxFiles
    }
  }

  public struct RetentionConfig: Codable, Sendable, Hashable {
    /// How long `logs/instances/<id>/` survives after the instance itself is gone. Distinct from
    /// `diagnostics.failedInstanceRetention`, which governs the *disk* directory of a VM that
    /// never came up: these are the logs kept after a perfectly successful job.
    public var instanceLogs: DurationValue

    public init(instanceLogs: DurationValue = .days(7)) {
      self.instanceLogs = instanceLogs
    }
  }

  public var file: FileConfig
  public var retention: RetentionConfig
  /// Pull the runner's `_diag` directory, the guest agent journal and the tail of `dmesg` out of
  /// an ephemeral guest before it is destroyed. Off means a failed job on an ephemeral VM leaves
  /// only host-side evidence.
  public var collectRunnerDiagnostics: Bool
  /// Hard bound on the collection exec. There is no top-level `timeouts:` section — the per-profile
  /// `timeouts:` block is a *profile* policy — so the one timeout this feature owns lives here.
  public var diagnosticsTimeout: DurationValue

  public init(
    file: FileConfig = FileConfig(),
    retention: RetentionConfig = RetentionConfig(),
    collectRunnerDiagnostics: Bool = true,
    diagnosticsTimeout: DurationValue = .seconds(60)
  ) {
    self.file = file
    self.retention = retention
    self.collectRunnerDiagnostics = collectRunnerDiagnostics
    self.diagnosticsTimeout = diagnosticsTimeout
  }

  /// Bytes a single collected tarball may reach before the host stops reading. Not configurable:
  /// it exists to bound a hostile guest, and an operator-tunable ceiling on that is a footgun.
  public static let maxDiagnosticsBytes: Int64 = 64 << 20
}

extension LoggingConfig {
  private enum CodingKeys: String, CodingKey {
    case file, retention, collectRunnerDiagnostics, diagnosticsTimeout
  }

  /// Every field defaults, so a document persisted before this section existed still decodes
  /// (spec §63/§91 back-compat).
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      file: try c.decodeIfPresent(FileConfig.self, forKey: .file) ?? FileConfig(),
      retention: try c.decodeIfPresent(RetentionConfig.self, forKey: .retention)
        ?? RetentionConfig(),
      collectRunnerDiagnostics: try c.decodeIfPresent(
        Bool.self, forKey: .collectRunnerDiagnostics) ?? true,
      diagnosticsTimeout: try c.decodeIfPresent(DurationValue.self, forKey: .diagnosticsTimeout)
        ?? .seconds(60)
    )
  }
}

extension LoggingConfig.FileConfig {
  private enum CodingKeys: String, CodingKey {
    case enabled, maxSizeBytes, maxFiles
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = LoggingConfig.FileConfig()
    self.init(
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled,
      maxSizeBytes: try c.decodeIfPresent(UInt64.self, forKey: .maxSizeBytes)
        ?? defaults.maxSizeBytes,
      maxFiles: try c.decodeIfPresent(Int.self, forKey: .maxFiles) ?? defaults.maxFiles
    )
  }
}

extension LoggingConfig.RetentionConfig {
  private enum CodingKeys: String, CodingKey {
    case instanceLogs
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      instanceLogs: try c.decodeIfPresent(DurationValue.self, forKey: .instanceLogs)
        ?? LoggingConfig.RetentionConfig().instanceLogs
    )
  }
}
