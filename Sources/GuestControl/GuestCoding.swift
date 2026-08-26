import Foundation
import RPC

/// Payload codec for the `guest` protocol.
///
/// Mirrors `WorkerProtocol.WorkerCoding`: a stock `JSONEncoder` writes `Date` as a reference-epoch
/// double, and Proto/envelope.md requires RFC 3339 strings with `Z`. Guest DTOs keep timestamps as
/// `String` (the Go agent formats them with `time.RFC3339`), so this pair exists for the base64
/// `Data` bridging and for the same array-wrapping trick WorkerCoding uses.
public enum GuestCoding {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.dataEncodingStrategy = .base64
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.dataDecodingStrategy = .base64
    return decoder
  }

  /// Encodes a DTO into a payload. Wrapped in an array because top-level JSON fragments are not
  /// universally accepted by `JSONSerialization`-style parsers.
  public static func payload(_ value: some Encodable) throws -> JSONValue {
    let data = try encoder().encode([value])
    guard case .array(let elements) = try StrictJSON.parse([UInt8](data)), let first = elements.first
    else {
      throw GuestCodingError.malformedPayload
    }
    return first
  }

  public static func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue?) throws -> T {
    let bytes = JSONValue.array([payload ?? .emptyObject]).encoded()
    guard let first = try decoder().decode([T].self, from: Data(bytes)).first else {
      throw GuestCodingError.malformedPayload
    }
    return first
  }

  /// `time.RFC3339` (no fractional seconds), which is what the Go agent emits.
  public static func timestamp(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// Accepts both the plain and the fractional-second spelling; hosts must not reject a guest
  /// that gained sub-second precision.
  public static func date(from text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    plain.timeZone = TimeZone(secondsFromGMT: 0)
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    fractional.timeZone = TimeZone(secondsFromGMT: 0)
    return fractional.date(from: text)
  }
}

public enum GuestCodingError: Error, Sendable, Equatable {
  case malformedPayload
}
