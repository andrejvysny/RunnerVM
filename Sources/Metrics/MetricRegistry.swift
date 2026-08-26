import Foundation

/// Declares a family before anything writes to it, so `GET /metrics` carries `# HELP` / `# TYPE`
/// for every metric RunnerVM knows about — including ones with no observation yet.
public struct MetricDefinition: Sendable, Hashable {
  public var name: String
  public var kind: MetricKind
  public var help: String
  /// Histogram upper bounds, ascending and excluding `+Inf`. Ignored for counters and gauges.
  public var buckets: [Double]

  public init(
    name: String, kind: MetricKind, help: String,
    buckets: [Double] = MetricRegistry.defaultSecondsBuckets
  ) {
    self.name = name
    self.kind = kind
    self.help = help
    self.buckets = kind == .histogram ? buckets.sorted() : []
  }
}

/// In-process metric store. Deliberately an injected instance rather than a process global: the
/// daemon owns exactly one, and a test owns as many as it likes without them bleeding into each
/// other (spec §43).
public actor MetricRegistry {
  /// Seconds buckets shared by every lifecycle timing in spec §41, so `image_pull_seconds` and
  /// `job_duration_seconds` can be compared on one dashboard.
  public static let defaultSecondsBuckets: [Double] = [
    0.1, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600,
  ]

  private struct Family {
    let kind: MetricKind
    let help: String
    let buckets: [Double]
    var scalars: [[MetricLabel]: Double] = [:]
    var histograms: [[MetricLabel]: MetricHistogram] = [:]
  }

  private var families: [String: Family] = [:]
  private let clock: @Sendable () -> Date

  public init(
    definitions: [MetricDefinition] = RunnerVMMetrics.definitions,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.clock = clock
    for definition in definitions where families[definition.name] == nil {
      families[definition.name] = Family(
        kind: definition.kind, help: definition.help, buckets: definition.buckets)
    }
  }

  public func define(_ definition: MetricDefinition) {
    guard families[definition.name] == nil else { return }
    families[definition.name] = Family(
      kind: definition.kind, help: definition.help, buckets: definition.buckets)
  }

  // MARK: - Writes

  /// Adds to a counter, or to a gauge that is being used as a running total.
  public func increment(_ name: String, labels: [String: String] = [:], by amount: Double = 1) {
    mutate(name, kind: .counter, labels: labels) { family, key in
      family.scalars[key, default: 0] += amount
    }
  }

  /// Mirrors a count the daemon already keeps elsewhere (reconcile runs, for instance) instead of
  /// double-counting it here. Never moves a counter backwards.
  public func setCounter(_ name: String, labels: [String: String] = [:], to value: Double) {
    mutate(name, kind: .counter, labels: labels) { family, key in
      family.scalars[key] = max(family.scalars[key] ?? 0, value)
    }
  }

  public func setGauge(_ name: String, labels: [String: String] = [:], to value: Double) {
    mutate(name, kind: .gauge, labels: labels) { family, key in
      family.scalars[key] = value
    }
  }

  /// Publishes the complete label set for a gauge in one step. Anything that was there before is
  /// dropped, which is how a `runnervm_instances{state="idle"}` series disappears once the last
  /// idle VM goes away instead of freezing at its final value.
  public func replaceGauge(_ name: String, with values: [([String: String], Double)]) {
    ensure(name, kind: .gauge)
    families[name]?.scalars = [:]
    for (labels, value) in values {
      families[name]?.scalars[Self.key(labels)] = value
    }
  }

  public func observe(_ name: String, labels: [String: String] = [:], seconds: Double) {
    guard seconds.isFinite else { return }
    ensure(name, kind: .histogram)
    guard var family = families[name] else { return }
    let key = Self.key(labels)
    var histogram = family.histograms[key]
      ?? MetricHistogram(
        buckets: family.buckets, counts: Array(repeating: 0, count: family.buckets.count + 1),
        sum: 0, count: 0)
    let index = family.buckets.firstIndex { seconds <= $0 } ?? family.buckets.count
    histogram.counts[index] += 1
    histogram.sum += seconds
    histogram.count += 1
    family.histograms[key] = histogram
    families[name] = family
  }

  /// `observe(name, seconds:)` for a `DispatchTime`-style span measured with the monotonic clock.
  public func observe(_ name: String, labels: [String: String] = [:], since start: ContinuousClock.Instant) {
    let elapsed = ContinuousClock.now - start
    let parts = elapsed.components
    observe(name, labels: labels, seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }

  // MARK: - Reads

  public func counter(name: String, labels: [String: String] = [:]) -> Double {
    families[name]?.scalars[Self.key(labels)] ?? 0
  }

  public func gauge(name: String, labels: [String: String] = [:]) -> Double? {
    families[name]?.scalars[Self.key(labels)]
  }

  public func histogram(name: String, labels: [String: String] = [:]) -> MetricHistogram? {
    families[name]?.histograms[Self.key(labels)]
  }

  public func snapshot() -> MetricsSnapshot {
    MetricsSnapshot(
      collectedAt: clock().ISO8601Format(),
      families: families
        .map { name, family in
          MetricFamily(
            name: name, type: family.kind, help: family.help, samples: samples(of: family))
        }
        .sorted { $0.name < $1.name })
  }

  // MARK: - Internals

  private func samples(of family: Family) -> [MetricSample] {
    let scalars = family.scalars.map { MetricSample(labels: $0.key, value: $0.value) }
    let histograms = family.histograms.map { MetricSample(labels: $0.key, histogram: $0.value) }
    return (scalars + histograms).sorted { Self.less($0.labels, $1.labels) }
  }

  private func mutate(
    _ name: String, kind: MetricKind, labels: [String: String],
    _ body: (inout Family, [MetricLabel]) -> Void
  ) {
    ensure(name, kind: kind)
    guard var family = families[name] else { return }
    body(&family, Self.key(labels))
    families[name] = family
  }

  private func ensure(_ name: String, kind: MetricKind) {
    guard families[name] == nil else { return }
    families[name] = Family(
      kind: kind, help: "", buckets: kind == .histogram ? Self.defaultSecondsBuckets : [])
  }

  /// Sorted, so `{a="1",b="2"}` and `{b="2",a="1"}` are the same series.
  static func key(_ labels: [String: String]) -> [MetricLabel] {
    labels.map { MetricLabel(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
  }

  static func less(_ lhs: [MetricLabel], _ rhs: [MetricLabel]) -> Bool {
    for (left, right) in zip(lhs, rhs) {
      if left.name != right.name { return left.name < right.name }
      if left.value != right.value { return left.value < right.value }
    }
    return lhs.count < rhs.count
  }
}
