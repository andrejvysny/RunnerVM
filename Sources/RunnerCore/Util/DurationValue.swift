import Foundation

/// A `Duration` that round-trips through configuration as "20m" / "1h30m" instead of Swift's
/// two-integer encoding, which is unreadable inside `runner_profiles.config_json`.
public struct DurationValue: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let duration: Duration

  public init(_ duration: Duration) {
    self.duration = duration
  }

  public static func < (lhs: DurationValue, rhs: DurationValue) -> Bool { lhs.duration < rhs.duration }

  public static let zero = DurationValue(.zero)
  public static func milliseconds(_ value: Int64) -> DurationValue { DurationValue(.milliseconds(value)) }
  public static func seconds(_ value: Int64) -> DurationValue { DurationValue(.seconds(value)) }
  public static func minutes(_ value: Int64) -> DurationValue { DurationValue(.seconds(value * 60)) }
  public static func hours(_ value: Int64) -> DurationValue { DurationValue(.seconds(value * 3600)) }
  public static func days(_ value: Int64) -> DurationValue { DurationValue(.seconds(value * 86400)) }

  /// Whole seconds, truncating sub-second precision. Timeouts are compared in seconds everywhere.
  public var seconds: Int64 { duration.components.seconds }

  public var isPositive: Bool { duration > .zero }

  // MARK: - Units

  private enum Unit: String, CaseIterable {
    case days = "d", hours = "h", minutes = "m", seconds = "s", milliseconds = "ms"

    /// Longest-suffix-first so "ms" is never mistaken for "s".
    static let matchOrder: [Unit] = [.milliseconds, .days, .hours, .minutes, .seconds]

    var milliseconds: Int64 {
      switch self {
      case .days: 86_400_000
      case .hours: 3_600_000
      case .minutes: 60_000
      case .seconds: 1_000
      case .milliseconds: 1
      }
    }
  }

  // MARK: - Parsing

  public struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public let input: String
    public var description: String { "invalid duration '\(input)'" }
  }

  public init(parsing text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ParseError(input: text) }
    var remainder = Substring(trimmed)
    var total: Int64 = 0
    var seen = Set<Unit>()
    while !remainder.isEmpty {
      let digits = remainder.prefix(while: \.isNumber)
      guard !digits.isEmpty, let value = Int64(digits) else { throw ParseError(input: text) }
      remainder = remainder.dropFirst(digits.count)
      guard let unit = Unit.matchOrder.first(where: { remainder.hasPrefix($0.rawValue) }) else {
        throw ParseError(input: text)
      }
      guard seen.insert(unit).inserted else { throw ParseError(input: text) }
      remainder = remainder.dropFirst(unit.rawValue.count)
      let (scaled, o1) = value.multipliedReportingOverflow(by: unit.milliseconds)
      let (sum, o2) = total.addingReportingOverflow(scaled)
      guard !o1, !o2 else { throw ParseError(input: text) }
      total = sum
    }
    self.init(.milliseconds(total))
  }

  // MARK: - Formatting

  public var description: String {
    var remaining = duration.components.seconds * 1_000
      + duration.components.attoseconds / 1_000_000_000_000_000
    guard remaining != 0 else { return "0s" }
    let sign = remaining < 0 ? "-" : ""
    remaining = abs(remaining)
    var out = ""
    for unit in [Unit.days, .hours, .minutes, .seconds, .milliseconds] {
      let count = remaining / unit.milliseconds
      if count > 0 {
        out += "\(count)\(unit.rawValue)"
        remaining -= count * unit.milliseconds
      }
    }
    return sign + out
  }
}

extension DurationValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    do {
      try self.init(parsing: text)
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid duration '\(text)'")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
