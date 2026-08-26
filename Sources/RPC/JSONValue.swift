import Foundation

/// A JSON document in memory.
///
/// Integers are kept distinct from doubles: the wire protocol uses signed 64-bit integers for
/// counts, byte sizes and timestamps, and float64 cannot represent them exactly beyond 2^53.
public enum JSONValue: Sendable, Hashable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case int(Int64)
  case double(Double)
  case bool(Bool)
  case null
}

public enum JSONValueError: Error, Sendable, Equatable {
  case bridgeFailed(String)
}

// MARK: - Accessors

extension JSONValue {
  public var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var intValue: Int64? {
    if case .int(let i) = self { return i }
    return nil
  }

  /// Doubles and integers both answer here; integers are widened.
  public var doubleValue: Double? {
    switch self {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  public static let emptyObject = JSONValue.object([:])
}

// MARK: - Codable bridging

extension JSONValue {
  /// Round-trips through JSON so that call sites can use ordinary `Codable` DTOs.
  public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
    let bytes = JSONValue.array([self]).encoded()
    // Wrapped in an array because top-level fragments are not universally accepted.
    let decoded = try JSONDecoder().decode([T].self, from: Data(bytes))
    guard let first = decoded.first else {
      throw JSONValueError.bridgeFailed("empty decode result")
    }
    return first
  }

  public init<T: Encodable>(encoding value: T) throws {
    let data = try JSONEncoder().encode([value])
    let parsed = try StrictJSON.parse([UInt8](data))
    guard case .array(let elements) = parsed, let first = elements.first else {
      throw JSONValueError.bridgeFailed("encoder did not produce a single value")
    }
    self = first
  }
}

// MARK: - Deterministic serialization

extension JSONValue {
  /// Serializes with object keys in sorted order so byte output is reproducible.
  public func encoded() -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(128)
    write(into: &out)
    return out
  }

  public func encodedString() -> String {
    String(decoding: encoded(), as: UTF8.self)
  }

  private func write(into out: inout [UInt8]) {
    switch self {
    case .null: out.append(contentsOf: Array("null".utf8))
    case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
    case .int(let i): out.append(contentsOf: Array(String(i).utf8))
    case .double(let d): JSONValue.writeDouble(d, into: &out)
    case .string(let s): JSONValue.writeString(s, into: &out)
    case .array(let a):
      out.append(UInt8(ascii: "["))
      for (index, element) in a.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        element.write(into: &out)
      }
      out.append(UInt8(ascii: "]"))
    case .object(let o):
      out.append(UInt8(ascii: "{"))
      for (index, key) in o.keys.sorted().enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        JSONValue.writeString(key, into: &out)
        out.append(UInt8(ascii: ":"))
        o[key]!.write(into: &out)
      }
      out.append(UInt8(ascii: "}"))
    }
  }

  /// JSON has no literal for infinity or NaN; emit null rather than invalid bytes.
  private static func writeDouble(_ value: Double, into out: inout [UInt8]) {
    guard value.isFinite else {
      out.append(contentsOf: Array("null".utf8))
      return
    }
    out.append(contentsOf: Array(String(value).utf8))
  }

  private static func writeString(_ value: String, into out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
      case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
      case 0x08: out.append(contentsOf: Array("\\b".utf8))
      case 0x09: out.append(contentsOf: Array("\\t".utf8))
      case 0x0A: out.append(contentsOf: Array("\\n".utf8))
      case 0x0C: out.append(contentsOf: Array("\\f".utf8))
      case 0x0D: out.append(contentsOf: Array("\\r".utf8))
      case 0x00...0x1F:
        out.append(contentsOf: Array("\\u00".utf8))
        out.append(hexDigit(byte >> 4))
        out.append(hexDigit(byte & 0x0F))
      default: out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }

  private static func hexDigit(_ nibble: UInt8) -> UInt8 {
    nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + (nibble - 10)
  }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}
