import Foundation

/// Prometheus metric types RunnerVM emits. `summary` and `untyped` are deliberately absent: every
/// timing in spec §41 is a histogram so buckets stay comparable across hosts.
public enum MetricKind: String, Codable, Sendable, Hashable, CaseIterable {
  case counter
  case gauge
  case histogram
}

/// One label pair. Stored as an ordered array rather than a dictionary so a snapshot encodes and
/// renders byte-identically every time.
public struct MetricLabel: Codable, Sendable, Hashable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

/// Cumulative histogram state. `counts[i]` is the number of observations in `(buckets[i-1],
/// buckets[i]]`; the trailing element counts everything above the last bound (`+Inf`), so
/// `counts.count == buckets.count + 1`.
public struct MetricHistogram: Codable, Sendable, Hashable {
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

  /// Prometheus exposes `le` buckets cumulatively; the registry stores them per-bucket.
  public var cumulativeCounts: [UInt64] {
    var running: UInt64 = 0
    return counts.map { bucket in
      running += bucket
      return running
    }
  }
}

/// One label set within a family. Exactly one of `value` / `histogram` is populated.
public struct MetricSample: Codable, Sendable, Hashable {
  public var labels: [MetricLabel]
  public var value: Double?
  public var histogram: MetricHistogram?

  public init(labels: [MetricLabel], value: Double? = nil, histogram: MetricHistogram? = nil) {
    self.labels = labels
    self.value = value
    self.histogram = histogram
  }
}

public struct MetricFamily: Codable, Sendable, Hashable {
  public var name: String
  public var type: MetricKind
  public var help: String
  public var samples: [MetricSample]

  public init(name: String, type: MetricKind, help: String, samples: [MetricSample]) {
    self.name = name
    self.type = type
    self.help = help
    self.samples = samples
  }
}

/// What `metrics.snapshot` and `GET /metrics` both render from. Families are sorted by name and
/// samples by label so two snapshots of the same state compare equal.
public struct MetricsSnapshot: Codable, Sendable, Hashable {
  /// RFC 3339, UTC.
  public var collectedAt: String
  public var families: [MetricFamily]

  public init(collectedAt: String, families: [MetricFamily]) {
    self.collectedAt = collectedAt
    self.families = families
  }

  public func family(_ name: String) -> MetricFamily? {
    families.first { $0.name == name }
  }
}
