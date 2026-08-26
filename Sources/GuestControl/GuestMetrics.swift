import Foundation

/// `agent.getMetrics` → the spec §39 telemetry snapshot.
///
/// Timestamps stay `String` rather than `Date`: the daemon forwards this value verbatim on
/// `instance.metrics`, and the daemon encoder is a stock `JSONEncoder` that would turn a `Date`
/// into a reference-epoch double. `timestampDate` is the typed accessor.
public struct GuestMetrics: Codable, Sendable, Equatable {
  public var timestamp: String
  public var uptimeSec: Int64
  public var cpu: CPUMetrics
  public var memory: MemoryMetrics
  public var disk: DiskMetrics
  public var runner: RunnerMetrics
  /// Sources the agent could not read. Absent when everything was collected.
  public var warnings: [String]?

  public init(
    timestamp: String, uptimeSec: Int64, cpu: CPUMetrics, memory: MemoryMetrics, disk: DiskMetrics,
    runner: RunnerMetrics, warnings: [String]? = nil
  ) {
    self.timestamp = timestamp
    self.uptimeSec = uptimeSec
    self.cpu = cpu
    self.memory = memory
    self.disk = disk
    self.runner = runner
    self.warnings = warnings
  }

  public var timestampDate: Date? { GuestCoding.date(from: timestamp) }

  /// Whole-guest processor telemetry. `usagePercent` is 0…100 across all cores; the load averages
  /// are the raw kernel values.
  public struct CPUMetrics: Codable, Sendable, Equatable {
    public var logicalCount: Int64
    public var usagePercent: Double
    public var load1: Double
    public var load5: Double
    public var load15: Double

    public init(
      logicalCount: Int64, usagePercent: Double, load1: Double, load5: Double, load15: Double
    ) {
      self.logicalCount = logicalCount
      self.usagePercent = usagePercent
      self.load1 = load1
      self.load5 = load5
      self.load15 = load15
    }
  }

  public struct MemoryMetrics: Codable, Sendable, Equatable {
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var availableBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
      self.totalBytes = totalBytes
      self.usedBytes = usedBytes
      self.availableBytes = availableBytes
    }
  }

  /// Capacity of the filesystem holding the guest root.
  public struct DiskMetrics: Codable, Sendable, Equatable {
    public var rootTotalBytes: Int64
    public var rootUsedBytes: Int64
    public var rootAvailableBytes: Int64

    public init(rootTotalBytes: Int64, rootUsedBytes: Int64, rootAvailableBytes: Int64) {
      self.rootTotalBytes = rootTotalBytes
      self.rootUsedBytes = rootUsedBytes
      self.rootAvailableBytes = rootAvailableBytes
    }
  }

  /// The actions-runner slice. `pid` is `0` and the samples are `0` when no runner is running.
  public struct RunnerMetrics: Codable, Sendable, Equatable {
    public var processRunning: Bool
    public var pid: Int64?
    public var cpuPercent: Double
    public var rssBytes: Int64

    public init(processRunning: Bool, pid: Int64? = nil, cpuPercent: Double, rssBytes: Int64) {
      self.processRunning = processRunning
      self.pid = pid
      self.cpuPercent = cpuPercent
      self.rssBytes = rssBytes
    }
  }
}
