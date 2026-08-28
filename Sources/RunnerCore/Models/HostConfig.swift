import Foundation

/// Host-wide capacity policy (spec §16, §17, §136).
public struct HostConfig: Codable, Sendable, Hashable {
  /// Headroom the orchestrator never hands to guests.
  public struct Reserve: Codable, Sendable, Hashable {
    public var cpu: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64

    public init(
      cpu: Int = 2,
      memoryBytes: UInt64 = ByteSize.gibibytes(6).bytes,
      diskBytes: UInt64 = ByteSize.gibibytes(50).bytes
    ) {
      self.cpu = cpu
      self.memoryBytes = memoryBytes
      self.diskBytes = diskBytes
    }
  }

  /// Ratios applied to the post-reserve budget. Memory overcommit should stay 1.0 (spec §16):
  /// a VZ guest touches its whole balloon, so overcommitting memory swaps the host to death.
  public struct Overcommit: Codable, Sendable, Hashable {
    public var cpu: Double
    public var memory: Double
    /// Ratio applied to the post-reserve *disk* budget (spec §17).
    ///
    /// Exists because admission reserves `max(profile.disk, image.virtualBytes)` — the guest disk's
    /// **apparent** size — while an instance disk is an APFS clone of the image that starts at
    /// nearly zero additional bytes and only grows as the job writes. The gap is small for Linux
    /// (a 16 GiB image really is 16 GiB) and large for macOS, whose Tart-derived image is 50 GB
    /// apparent against 30.6 GiB allocated and whose `resources.disk` must equal that apparent
    /// size exactly. Measured: a full macOS job left free disk unchanged at 83 GiB.
    ///
    /// Left at 1.0 admission stays fail-closed — a job that writes every block of its disk still
    /// fits. Above 1.0 you are asserting that your guests do not, and accepting that one which
    /// does can exhaust host storage underneath the daemon and every other VM.
    public var disk: Double

    public init(cpu: Double = 1.0, memory: Double = 1.0, disk: Double = 1.0) {
      self.cpu = cpu
      self.memory = memory
      self.disk = disk
    }
  }

  /// Absolute VM count ceiling, independent of the resource budget.
  public enum MaxVMs: Sendable, Hashable {
    case auto
    case count(Int)

    public func resolved(fittingBudget: Int) -> Int {
      switch self {
      case .auto: fittingBudget
      case .count(let n): min(n, fittingBudget)
      }
    }
  }

  /// Startup concurrency is deliberately separate from final capacity: six simultaneous macOS
  /// boots degrade the host even when all six would fit (spec §136).
  public struct Limits: Codable, Sendable, Hashable {
    public var concurrentImagePulls: Int
    public var concurrentVMStarts: Int

    public init(concurrentImagePulls: Int = 2, concurrentVMStarts: Int = 2) {
      self.concurrentImagePulls = concurrentImagePulls
      self.concurrentVMStarts = concurrentVMStarts
    }
  }

  public var reserve: Reserve
  public var overcommit: Overcommit
  public var maxVMs: MaxVMs
  public var limits: Limits

  public init(
    reserve: Reserve = Reserve(),
    overcommit: Overcommit = Overcommit(),
    maxVMs: MaxVMs = .auto,
    limits: Limits = Limits()
  ) {
    self.reserve = reserve
    self.overcommit = overcommit
    self.maxVMs = maxVMs
    self.limits = limits
  }

  public static let `default` = HostConfig()
}

extension HostConfig.MaxVMs: Codable {
  private static let autoToken = "auto"

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let count = try? container.decode(Int.self) {
      self = .count(count)
      return
    }
    let text = try container.decode(String.self)
    guard text == Self.autoToken else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "maxVMs must be an integer or \"auto\""
      )
    }
    self = .auto
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .auto: try container.encode(Self.autoToken)
    case .count(let n): try container.encode(n)
    }
  }
}

extension HostConfig.Overcommit {
  private enum CodingKeys: String, CodingKey {
    case cpu, memory, disk
  }

  /// Per-key leniency, like `HostConfig` itself: a configuration persisted before `disk` existed
  /// must still load, and it means "no disk overcommit" rather than failing to decode.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = HostConfig.Overcommit()
    self.init(
      cpu: try c.decodeIfPresent(Double.self, forKey: .cpu) ?? d.cpu,
      memory: try c.decodeIfPresent(Double.self, forKey: .memory) ?? d.memory,
      disk: try c.decodeIfPresent(Double.self, forKey: .disk) ?? d.disk
    )
  }
}

extension HostConfig {
  private enum CodingKeys: String, CodingKey {
    case reserve, overcommit, maxVMs, limits
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      reserve: try c.decodeIfPresent(Reserve.self, forKey: .reserve) ?? Reserve(),
      overcommit: try c.decodeIfPresent(Overcommit.self, forKey: .overcommit) ?? Overcommit(),
      maxVMs: try c.decodeIfPresent(MaxVMs.self, forKey: .maxVMs) ?? .auto,
      limits: try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
    )
  }
}
