import Foundation
import RPC

/// Payload codec for the `worker` protocol.
///
/// `JSONValue(encoding:)` uses a stock `JSONEncoder`, which writes `Date` as a reference-epoch
/// double; Proto/envelope.md requires RFC 3339 strings with `Z`. Every worker DTO therefore goes
/// through this pair instead of the generic bridge.
public enum WorkerCoding {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Encodes a DTO into a payload. Wrapped in an array because top-level JSON fragments are not
  /// universally accepted by `JSONSerialization`-style parsers.
  public static func payload(_ value: some Encodable) throws -> JSONValue {
    let data = try encoder().encode([value])
    guard case .array(let elements) = try StrictJSON.parse([UInt8](data)), let first = elements.first
    else {
      throw WorkerCodingError.malformedPayload
    }
    return first
  }

  public static func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue?) throws -> T {
    let bytes = JSONValue.array([payload ?? .emptyObject]).encoded()
    guard let first = try decoder().decode([T].self, from: Data(bytes)).first else {
      throw WorkerCodingError.malformedPayload
    }
    return first
  }
}

public enum WorkerCodingError: Error, Sendable, Equatable {
  case malformedPayload
}
