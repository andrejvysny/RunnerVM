import Foundation
import GRDB

/// A timestamp stored as ISO-8601 `TEXT` (UTC, fractional seconds) rather than GRDB's default
/// `Date` encoding (`yyyy-MM-dd HH:mm:ss.SSS`, space-separated, no zone suffix). All `*_at`
/// columns in `docs/db_schema_v1.sql` use this format, so every Record uses `DatabaseDate`
/// instead of `Date` directly.
public struct DatabaseDate: Hashable, Sendable, Comparable {
  public var date: Date

  public init(_ date: Date) { self.date = date }

  public static var now: DatabaseDate { DatabaseDate(Date()) }

  public static func < (lhs: DatabaseDate, rhs: DatabaseDate) -> Bool { lhs.date < rhs.date }

  // `ISO8601DateFormatter` is a mutable reference type with no documented Sendable guarantee, so
  // a fresh instance is built per call rather than cached in a shared `static let` — the only way
  // to keep this type an unconditional `Sendable` value under Swift 6 strict concurrency.
  private static func makeFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  static func string(from date: Date) -> String { makeFormatter().string(from: date) }

  static func parse(_ text: String) -> Date? { makeFormatter().date(from: text) }
}

extension DatabaseDate: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { Self.string(from: date).databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DatabaseDate? {
    guard let text = String.fromDatabaseValue(dbValue), let date = Self.parse(text) else { return nil }
    return DatabaseDate(date)
  }
}

extension DatabaseDate: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let date = Self.parse(text) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date '\(text)'")
    }
    self.date = date
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Self.string(from: date))
  }
}
