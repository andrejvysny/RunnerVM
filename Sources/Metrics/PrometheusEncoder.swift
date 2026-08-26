import Foundation

/// Prometheus text exposition format 0.0.4 (spec §43). Hand-rolled on purpose: RunnerVM ships no
/// third-party runtime dependencies, and the format is a dozen lines of rules.
public enum PrometheusEncoder {
  public static let contentType = "text/plain; version=0.0.4; charset=utf-8"

  public static func encode(_ snapshot: MetricsSnapshot) -> String {
    var out = ""
    for family in snapshot.families {
      out += "# HELP \(family.name) \(escapeHelp(family.help))\n"
      out += "# TYPE \(family.name) \(family.type.rawValue)\n"
      for sample in family.samples {
        out += line(family: family, sample: sample)
      }
    }
    return out
  }

  private static func line(family: MetricFamily, sample: MetricSample) -> String {
    guard let histogram = sample.histogram else {
      guard let value = sample.value else { return "" }
      return "\(family.name)\(labels(sample.labels)) \(format(value))\n"
    }
    var out = ""
    let cumulative = histogram.cumulativeCounts
    for (index, bound) in histogram.buckets.enumerated() {
      out += bucketLine(family.name, sample.labels, le: format(bound), count: cumulative[index])
    }
    out += bucketLine(family.name, sample.labels, le: "+Inf", count: histogram.count)
    out += "\(family.name)_sum\(labels(sample.labels)) \(format(histogram.sum))\n"
    out += "\(family.name)_count\(labels(sample.labels)) \(histogram.count)\n"
    return out
  }

  /// `le` is a real label, so it participates in the same ordering the rest of the set uses and
  /// has to be rendered inside the same braces.
  private static func bucketLine(
    _ name: String, _ base: [MetricLabel], le: String, count: UInt64
  ) -> String {
    let all = base + [MetricLabel(name: "le", value: le)]
    return "\(name)_bucket\(labels(all)) \(count)\n"
  }

  private static func labels(_ labels: [MetricLabel]) -> String {
    guard !labels.isEmpty else { return "" }
    let body = labels
      .map { "\($0.name)=\"\(escapeValue($0.value))\"" }
      .joined(separator: ",")
    return "{\(body)}"
  }

  /// Whole numbers print without a fractional part so a counter reads as `3`, not `3.0`; anything
  /// else uses Swift's shortest round-trip form.
  static func format(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "+Inf" : "-Inf" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  /// Only backslash and newline are special in `# HELP`; a quote is an ordinary character there.
  static func escapeHelp(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  static func escapeValue(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}
