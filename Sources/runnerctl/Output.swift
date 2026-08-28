import ArgumentParser
import Foundation

enum OutputMode: String, ExpressibleByArgument, CaseIterable, Sendable {
  case human
  case json
}

/// Options every subcommand accepts. Declared on the root command too, so
/// `runnerctl --socket <path> status` and `runnerctl status --socket <path>` both work.
struct GlobalOptions: ParsableArguments {
  @Option(
    name: .long,
    help: ArgumentHelp(
      "Path to runnerd.sock.",
      discussion: "Falls back to RUNNERVM_SOCKET, then the production socket when it exists, "
        + "then the development one."))
  var socket: String?

  @Option(name: .long, help: "human or json.")
  var output: OutputMode = .human
}

enum Format {
  /// Exact binary multiples keep their unit ("8GiB"); anything else rounds to one decimal so a
  /// free-disk figure does not print as a raw byte count.
  static func bytes(_ value: UInt64) -> String {
    guard value > 0 else { return "0B" }
    let units: [(String, UInt64)] = [
      ("TiB", 1 << 40), ("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10),
    ]
    for (name, factor) in units where value >= factor {
      if value % factor == 0 { return "\(value / factor)\(name)" }
      return String(format: "%.1f%@", Double(value) / Double(factor), name)
    }
    return "\(value)B"
  }

  static func duration(seconds: Int64) -> String {
    switch seconds {
    case ..<60: "\(seconds)s"
    case ..<3_600: "\(seconds / 60)m\(seconds % 60)s"
    case ..<86_400: "\(seconds / 3_600)h\((seconds % 3_600) / 60)m"
    default: "\(seconds / 86_400)d\((seconds % 86_400) / 3_600)h"
    }
  }

  static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

  /// `sha256:abc123de` — enough to identify an image in a table without wrapping the line.
  static func shortDigest(_ digest: String) -> String {
    guard let body = digest.split(separator: ":").last, body.count > 12 else { return digest }
    let prefix = digest.hasPrefix("sha256:") ? "sha256:" : ""
    return prefix + body.prefix(12)
  }

  static func optional(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "-" }
    return value
  }
}

/// Left-aligned fixed-width table. No third-party dependency: the daemon API is the stable
/// contract, human output is deliberately plain.
enum Table {
  static func render(headers: [String], rows: [[String]]) -> String {
    guard !rows.isEmpty else { return headers.joined(separator: "  ") + "\n(none)" }
    var widths = headers.map { $0.count }
    for row in rows {
      for (index, cell) in row.enumerated() where index < widths.count {
        widths[index] = max(widths[index], cell.count)
      }
    }
    var lines = [line(headers, widths)]
    lines.append(contentsOf: rows.map { line($0, widths) })
    return lines.joined(separator: "\n")
  }

  private static func line(_ cells: [String], _ widths: [Int]) -> String {
    cells.enumerated()
      .map { index, cell in
        index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
      }
      .joined(separator: "  ")
      .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
  }

  /// `label: value` block used by `status`.
  static func fields(_ pairs: [(String, String)], indent: String = "  ") -> String {
    let width = pairs.map(\.0.count).max() ?? 0
    return pairs
      .map { "\(indent)\(($0.0 + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0))  \($0.1)" }
      .joined(separator: "\n")
  }
}

enum JSONOut {
  static func print<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    Swift.print(String(decoding: try encoder.encode(value), as: UTF8.self))
  }
}

func writeError(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}
