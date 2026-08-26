import ArgumentParser
import DaemonAPI
import Foundation

enum MetricsFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
  case human
  case json
  case prometheus
}

/// Spec §43: the snapshot every RunnerVM install has, with or without a Prometheus endpoint.
struct MetricsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "metrics",
    abstract: "Show the daemon's metric snapshot.",
    discussion: """
      --format prometheus renders the same text the optional local endpoint serves, so a scrape \
      can be reproduced without enabling metrics.prometheus.
      """)

  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "human, json or prometheus. Defaults to --output.")
  var format: MetricsFormat?

  func run() async throws {
    let format = format ?? (options.output == .json ? .json : .human)
    let response = try await options.withDaemon {
      try await $0.metricsSnapshot(format: format == .prometheus ? .prometheus : .json)
    }
    switch format {
    case .json: try JSONOut.print(response)
    case .prometheus: print(response.prometheus ?? "", terminator: "")
    case .human: print(MetricsCommand.render(response))
    }
  }

  /// Families with no observation yet are counted rather than listed: the catalogue is long, and
  /// an operator reading a table wants the series that exist.
  static func render(_ response: MetricsSnapshotResponse) -> String {
    var rows: [[String]] = []
    var empty = 0
    for family in response.families.sorted(by: { $0.name < $1.name }) {
      guard !family.samples.isEmpty else {
        empty += 1
        continue
      }
      for sample in family.samples {
        rows.append([series(family.name, sample.labels), value(sample)])
      }
    }
    var out = Table.render(headers: ["METRIC", "VALUE"], rows: rows)
    out += "\n\ncollected at \(response.collectedAt)"
    if empty > 0 { out += "; \(empty) declared families have no observation yet" }
    return out
  }

  private static func series(_ name: String, _ labels: [MetricLabelDTO]) -> String {
    guard !labels.isEmpty else { return name }
    return name + "{" + labels.map { "\($0.name)=\($0.value)" }.joined(separator: ",") + "}"
  }

  private static func value(_ sample: MetricSampleDTO) -> String {
    if let histogram = sample.histogram {
      let mean = histogram.count == 0 ? 0 : histogram.sum / Double(histogram.count)
      return String(format: "count %llu, mean %.2fs", histogram.count, mean)
    }
    guard let value = sample.value else { return "-" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(format: "%.3f", value)
  }
}
