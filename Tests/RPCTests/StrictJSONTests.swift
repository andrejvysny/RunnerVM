import Foundation
import Testing

@testable import RPC

@Suite struct StrictJSONTests {
  @Test func rejectsDuplicateKeysAtAnyDepth() {
    #expect(throws: StrictJSONError.duplicateKey("a")) {
      try StrictJSON.parse(#"{"a":1,"a":2}"#)
    }
    #expect(throws: StrictJSONError.duplicateKey("b")) {
      try StrictJSON.parse(#"{"outer":{"deep":[{"b":1,"b":2}]}}"#)
    }
  }

  @Test func rejectsTrailingAndEmptyInput() {
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse("{} x") }
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse("{}{}") }
    #expect(throws: StrictJSONError.empty) { try StrictJSON.parse("") }
    #expect(throws: StrictJSONError.unexpectedEnd) { try StrictJSON.parse("   ") }
  }

  @Test func enforcesDepthLimit() throws {
    let atLimit = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
    _ = try StrictJSON.parse(atLimit)
    let overLimit = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
    #expect(throws: StrictJSONError.depthExceeded) { try StrictJSON.parse(overLimit) }
    let mixed = String(repeating: #"{"k":"#, count: 65) + "1" + String(repeating: "}", count: 65)
    #expect(throws: StrictJSONError.depthExceeded) { try StrictJSON.parse(mixed) }
  }

  @Test func rejectsInvalidUTF8InsideStrings() {
    var bytes = Array(#"{"k":"x"}"#.utf8)
    bytes[6] = 0xC3  // truncated two-byte sequence
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse(bytes) }
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse([0x22, 0xED, 0xA0, 0x80, 0x22]) }
  }

  @Test func integersNeverBecomeDoubles() throws {
    #expect(try StrictJSON.parse("9007199254740993") == .int(9_007_199_254_740_993))
    #expect(try StrictJSON.parse("-9223372036854775808") == .int(Int64.min))
    #expect(try StrictJSON.parse("9223372036854775807") == .int(Int64.max))
    // One past Int64.max cannot be represented, so it degrades to a double rather than wrapping.
    #expect(try StrictJSON.parse("9223372036854775808").intValue == nil)
    #expect(try StrictJSON.parse("1.0") == .double(1.0))
    #expect(try StrictJSON.parse("1e2") == .double(100))
  }

  @Test func rejectsMalformedNumbers() {
    for text in ["01", "1.", ".5", "1e", "+1", "-", "1e+"] {
      #expect(throws: StrictJSONError.self, "accepted \(text)") { try StrictJSON.parse(text) }
    }
  }

  @Test func handlesEscapesAndSurrogatePairs() throws {
    #expect(try StrictJSON.parse(#""aA\n\"\\""#) == .string("aA\n\"\\"))
    #expect(try StrictJSON.parse(#""😀""#) == .string("\u{1F600}"))
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse(#""\ud83d""#) }
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse(#""\q""#) }
    #expect(throws: StrictJSONError.self) { try StrictJSON.parse("\"raw\u{01}control\"") }
  }

  @Test func roundTripsThroughCodable() throws {
    struct Lease: Codable, Equatable {
      let id: String
      let ttlMs: Int64
      let tags: [String]
    }
    let lease = Lease(id: "l1", ttlMs: 9_007_199_254_740_993, tags: ["a", "b"])
    let value = try JSONValue(encoding: lease)
    #expect(value["ttlMs"] == .int(9_007_199_254_740_993))
    #expect(try value.decode(as: Lease.self) == lease)
  }

  @Test func parsesLargePayloadsInOnePass() throws {
    let element = #"{"stream":"stdout","data":"aGVsbG8gd29ybGQgZnJvbSB0aGUgZ3Vlc3Q="},"#
    let repeats = (4 << 20) / element.utf8.count
    let text = "[" + String(repeating: element, count: repeats) + #"{"stream":"stderr"}]"#
    #expect(text.utf8.count > 4 << 20)
    let parsed = try StrictJSON.parse(text)
    #expect(parsed.arrayValue?.count == repeats + 1)
  }
}
