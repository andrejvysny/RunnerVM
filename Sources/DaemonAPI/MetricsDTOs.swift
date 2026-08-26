import Foundation

/// `metrics.snapshot` (spec §43). The wire shape mirrors `Metrics.MetricsSnapshot` field for
/// field; the daemon maps between them, because `DaemonAPI` sits below `Metrics` in the module
/// graph and `runnerctl` links neither.
public struct MetricsSnapshotRequest: Codable, Sendable, Hashable {
  public enum Format: String, Codable, Sendable, CaseIterable {
    case json
    /// Asks the daemon to render the Prometheus text itself, so the CLI never has to own a second
    /// copy of the exposition format.
    case prometheus
  }

  public var format: Format

  public init(format: Format = .json) {
    self.format = format
  }

  /// Lenient: an empty payload means "the default snapshot", so a caller poking the method by
  /// hand gets an answer rather than `INVALID_PARAMS`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try container.decodeIfPresent(Format.self, forKey: .format) ?? .json
  }
}

public struct MetricLabelDTO: Codable, Sendable, Hashable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

/// `counts[i]` holds the observations in bucket `i`; the trailing element is `+Inf`.
public struct MetricHistogramDTO: Codable, Sendable, Hashable {
  public var buckets: [Double]
  public var counts: [UInt64]
  public var sum: Double
  public var count: UInt64

  public init(buckets: [Double], counts: [UInt64], sum: Double, count: UInt64) {
    self.buckets = buckets
    self.counts = counts
    self.sum = sum
    self.count = count
  }
}

public struct MetricSampleDTO: Codable, Sendable, Hashable {
  public var labels: [MetricLabelDTO]
  public var value: Double?
  public var histogram: MetricHistogramDTO?

  public init(
    labels: [MetricLabelDTO], value: Double? = nil, histogram: MetricHistogramDTO? = nil
  ) {
    self.labels = labels
    self.value = value
    self.histogram = histogram
  }

  public func label(_ name: String) -> String? {
    labels.first { $0.name == name }?.value
  }
}

public struct MetricFamilyDTO: Codable, Sendable, Hashable {
  public var name: String
  /// `counter`, `gauge` or `histogram`.
  public var type: String
  public var help: String
  public var samples: [MetricSampleDTO]

  public init(name: String, type: String, help: String, samples: [MetricSampleDTO]) {
    self.name = name
    self.type = type
    self.help = help
    self.samples = samples
  }
}

public struct MetricsSnapshotResponse: Codable, Sendable, Hashable {
  public var collectedAt: String
  public var families: [MetricFamilyDTO]
  /// Populated only for `format: prometheus`; the exposition text is large and every other caller
  /// would pay for it.
  public var prometheus: String?

  public init(collectedAt: String, families: [MetricFamilyDTO], prometheus: String? = nil) {
    self.collectedAt = collectedAt
    self.families = families
    self.prometheus = prometheus
  }

  public func family(_ name: String) -> MetricFamilyDTO? {
    families.first { $0.name == name }
  }
}
