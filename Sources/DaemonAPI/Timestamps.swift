import Foundation

/// `Proto/envelope.md`: timestamps travel as RFC 3339 strings with `Z`, never as the numeric
/// `Date` encoding `JSONEncoder` would otherwise produce.
public enum RFC3339 {
  // A fresh formatter per call: `ISO8601DateFormatter` is a mutable reference type with no
  // documented Sendable guarantee (same reasoning as `Persistence.DatabaseDate`).
  private static func formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  public static func string(from date: Date) -> String { formatter().string(from: date) }

  public static func date(from text: String) -> Date? { formatter().date(from: text) }
}
