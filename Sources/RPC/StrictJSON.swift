import Foundation

public enum StrictJSONError: Error, Sendable, Equatable {
  case empty
  case unexpectedByte(offset: Int)
  case unexpectedEnd
  case trailingBytes(offset: Int)
  case duplicateKey(String)
  case depthExceeded
  case invalidUTF8(offset: Int)
  case invalidNumber(offset: Int)
  case invalidEscape(offset: Int)
}

/// Single-pass JSON reader with the strictness the RPC protocol requires.
///
/// `JSONDecoder` cannot report duplicate object keys or trailing bytes, both of which are
/// request-smuggling vectors when a host and a guest disagree about which value wins.
public enum StrictJSON {
  public static let maxDepth = 64

  public static func parse(_ bytes: UnsafeRawBufferPointer) throws -> JSONValue {
    guard !bytes.isEmpty else { throw StrictJSONError.empty }
    var parser = JSONParser(bytes: bytes)
    return try parser.parseDocument()
  }

  public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
    try bytes.withUnsafeBytes { try parse($0) }
  }

  public static func parse(_ text: String) throws -> JSONValue {
    try parse(Array(text.utf8))
  }
}

struct JSONParser {
  let bytes: UnsafeRawBufferPointer
  var index = 0
  var depth = 0

  mutating func parseDocument() throws -> JSONValue {
    skipWhitespace()
    guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
    let value = try parseValue()
    skipWhitespace()
    guard index == bytes.count else { throw StrictJSONError.trailingBytes(offset: index) }
    return value
  }

  private mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  private mutating func parseValue() throws -> JSONValue {
    guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try parseObject()
    case UInt8(ascii: "["): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
    default: throw StrictJSONError.unexpectedByte(offset: index)
    }
  }

  private mutating func expect(_ literal: String) throws {
    let expected = Array(literal.utf8)
    guard index + expected.count <= bytes.count else { throw StrictJSONError.unexpectedEnd }
    for (offset, byte) in expected.enumerated() where bytes[index + offset] != byte {
      throw StrictJSONError.unexpectedByte(offset: index + offset)
    }
    index += expected.count
  }

  private mutating func parseObject() throws -> JSONValue {
    index += 1
    depth += 1
    defer { depth -= 1 }
    guard depth <= StrictJSON.maxDepth else { throw StrictJSONError.depthExceeded }
    var result: [String: JSONValue] = [:]
    skipWhitespace()
    if try consume(UInt8(ascii: "}")) { return .object(result) }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
        throw StrictJSONError.unexpectedByte(offset: min(index, bytes.count - 1))
      }
      let key = try parseString()
      skipWhitespace()
      guard try consume(UInt8(ascii: ":")) else { throw StrictJSONError.unexpectedByte(offset: index) }
      skipWhitespace()
      let value = try parseValue()
      guard result.updateValue(value, forKey: key) == nil else {
        throw StrictJSONError.duplicateKey(key)
      }
      skipWhitespace()
      if try consume(UInt8(ascii: ",")) { continue }
      if try consume(UInt8(ascii: "}")) { return .object(result) }
      throw index < bytes.count
        ? StrictJSONError.unexpectedByte(offset: index) : StrictJSONError.unexpectedEnd
    }
  }

  private mutating func parseArray() throws -> JSONValue {
    index += 1
    depth += 1
    defer { depth -= 1 }
    guard depth <= StrictJSON.maxDepth else { throw StrictJSONError.depthExceeded }
    var result: [JSONValue] = []
    skipWhitespace()
    if try consume(UInt8(ascii: "]")) { return .array(result) }
    while true {
      skipWhitespace()
      result.append(try parseValue())
      skipWhitespace()
      if try consume(UInt8(ascii: ",")) { continue }
      if try consume(UInt8(ascii: "]")) { return .array(result) }
      throw index < bytes.count
        ? StrictJSONError.unexpectedByte(offset: index) : StrictJSONError.unexpectedEnd
    }
  }

  private mutating func consume(_ byte: UInt8) throws -> Bool {
    guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
    guard bytes[index] == byte else { return false }
    index += 1
    return true
  }
}

// MARK: - Strings

extension JSONParser {
  mutating func parseString() throws -> String {
    index += 1
    let start = index
    var hasEscape = false
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\"") {
        let end = index
        index += 1
        guard UTF8Validator.isValid(bytes, from: start, to: end) else {
          throw StrictJSONError.invalidUTF8(offset: start)
        }
        if !hasEscape {
          return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        }
        return try unescape(from: start, to: end)
      }
      if byte < 0x20 { throw StrictJSONError.unexpectedByte(offset: index) }
      if byte == UInt8(ascii: "\\") {
        hasEscape = true
        index += 1
        guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
      }
      index += 1
    }
    throw StrictJSONError.unexpectedEnd
  }

  private func unescape(from start: Int, to end: Int) throws -> String {
    var out: [UInt8] = []
    out.reserveCapacity(end - start)
    var cursor = start
    while cursor < end {
      let byte = bytes[cursor]
      guard byte == UInt8(ascii: "\\") else {
        out.append(byte)
        cursor += 1
        continue
      }
      cursor += 1
      guard cursor < end else { throw StrictJSONError.invalidEscape(offset: cursor) }
      switch bytes[cursor] {
      case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); cursor += 1
      case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); cursor += 1
      case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); cursor += 1
      case UInt8(ascii: "b"): out.append(0x08); cursor += 1
      case UInt8(ascii: "f"): out.append(0x0C); cursor += 1
      case UInt8(ascii: "n"): out.append(0x0A); cursor += 1
      case UInt8(ascii: "r"): out.append(0x0D); cursor += 1
      case UInt8(ascii: "t"): out.append(0x09); cursor += 1
      case UInt8(ascii: "u"): cursor = try appendUnicodeEscape(at: cursor, limit: end, into: &out)
      default: throw StrictJSONError.invalidEscape(offset: cursor)
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private func appendUnicodeEscape(at position: Int, limit: Int, into out: inout [UInt8]) throws -> Int {
    var cursor = position + 1
    var scalarValue = UInt32(try readHex4(at: cursor, limit: limit))
    cursor += 4
    if (0xD800...0xDBFF).contains(scalarValue) {
      guard cursor + 6 <= limit, bytes[cursor] == UInt8(ascii: "\\"),
        bytes[cursor + 1] == UInt8(ascii: "u")
      else { throw StrictJSONError.invalidEscape(offset: cursor) }
      let low = UInt32(try readHex4(at: cursor + 2, limit: limit))
      guard (0xDC00...0xDFFF).contains(low) else { throw StrictJSONError.invalidEscape(offset: cursor) }
      scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
      cursor += 6
    } else if (0xDC00...0xDFFF).contains(scalarValue) {
      throw StrictJSONError.invalidEscape(offset: position)
    }
    guard let scalar = Unicode.Scalar(scalarValue) else {
      throw StrictJSONError.invalidEscape(offset: position)
    }
    out.append(contentsOf: Array(String(scalar).utf8))
    return cursor
  }

  private func readHex4(at position: Int, limit: Int) throws -> UInt16 {
    guard position + 4 <= limit else { throw StrictJSONError.invalidEscape(offset: position) }
    var value: UInt16 = 0
    for offset in 0..<4 {
      let byte = bytes[position + offset]
      let digit: UInt16
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a")) + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A")) + 10
      default: throw StrictJSONError.invalidEscape(offset: position + offset)
      }
      value = value << 4 | digit
    }
    return value
  }
}

// MARK: - Numbers

extension JSONParser {
  mutating func parseNumber() throws -> JSONValue {
    let start = index
    let negative = bytes[index] == UInt8(ascii: "-")
    if negative { index += 1 }
    let digitsStart = index
    guard index < bytes.count, isDigit(bytes[index]) else {
      throw StrictJSONError.invalidNumber(offset: start)
    }
    if bytes[index] == UInt8(ascii: "0") {
      index += 1
    } else {
      while index < bytes.count, isDigit(bytes[index]) { index += 1 }
    }
    var isInteger = true
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      isInteger = false
      index += 1
      try consumeDigits(startingAt: start)
    }
    if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
      isInteger = false
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
        index += 1
      }
      try consumeDigits(startingAt: start)
    }
    if isInteger, let value = integer(from: digitsStart, to: index, negative: negative) {
      return .int(value)
    }
    let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    guard let value = Double(text) else { throw StrictJSONError.invalidNumber(offset: start) }
    return .double(value)
  }

  private mutating func consumeDigits(startingAt start: Int) throws {
    guard index < bytes.count, isDigit(bytes[index]) else {
      throw StrictJSONError.invalidNumber(offset: start)
    }
    while index < bytes.count, isDigit(bytes[index]) { index += 1 }
  }

  /// Returns nil when the literal does not fit `Int64`, so the caller can fall back to `Double`.
  private func integer(from start: Int, to end: Int, negative: Bool) -> Int64? {
    var magnitude: UInt64 = 0
    let limit: UInt64 = negative ? 9_223_372_036_854_775_808 : 9_223_372_036_854_775_807
    for cursor in start..<end {
      let (multiplied, overflow1) = magnitude.multipliedReportingOverflow(by: 10)
      guard !overflow1 else { return nil }
      let (added, overflow2) = multiplied.addingReportingOverflow(UInt64(bytes[cursor] - UInt8(ascii: "0")))
      guard !overflow2, added <= limit else { return nil }
      magnitude = added
    }
    if negative { return magnitude == limit ? Int64.min : -Int64(magnitude) }
    return Int64(magnitude)
  }

  private func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }
}

// MARK: - UTF-8

enum UTF8Validator {
  /// Rejects overlong forms, surrogates and truncated sequences that `String(decoding:)` would
  /// silently replace with U+FFFD.
  static func isValid(_ bytes: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Bool {
    var index = start
    while index < end {
      let byte = bytes[index]
      if byte < 0x80 {
        index += 1
        continue
      }
      let length: Int
      let minimum: UInt32
      var scalar: UInt32
      switch byte {
      case 0xC0...0xDF: length = 2; minimum = 0x80; scalar = UInt32(byte & 0x1F)
      case 0xE0...0xEF: length = 3; minimum = 0x800; scalar = UInt32(byte & 0x0F)
      case 0xF0...0xF7: length = 4; minimum = 0x10000; scalar = UInt32(byte & 0x07)
      default: return false
      }
      guard index + length <= end else { return false }
      for offset in 1..<length {
        let continuation = bytes[index + offset]
        guard continuation & 0xC0 == 0x80 else { return false }
        scalar = scalar << 6 | UInt32(continuation & 0x3F)
      }
      guard scalar >= minimum, scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else {
        return false
      }
      index += length
    }
    return true
  }
}
