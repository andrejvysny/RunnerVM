import Foundation
import RunnerCore
import Testing

@Suite struct ByteSizeTests {
  // The literal array is annotated and hoisted: Swift 6.1's type checker times out inferring a
  // 14-element array of heterogeneous tuples inside the @Test macro expansion.
  static let knownForms: [(input: String, expected: UInt64)] = [
    ("8GiB", UInt64(8) << 30),
    ("512MiB", UInt64(512) << 20),
    ("1.5GiB", UInt64(1536) << 20),
    ("80GB", UInt64(80_000_000_000)),
    ("120GiB", UInt64(120) << 30),
    ("1KiB", UInt64(1024)),
    ("4096", UInt64(4096)),
    ("4096B", UInt64(4096)),
    ("0", UInt64(0)),
    ("1TiB", UInt64(1) << 40),
    ("1PiB", UInt64(1) << 50),
    ("2KB", UInt64(2000)),
    (" 6GiB ", UInt64(6) << 30),
    ("8gib", UInt64(8) << 30),
  ]

  @Test(arguments: knownForms)
  func parsesKnownForms(input: String, expected: UInt64) throws {
    #expect(try ByteSize(parsing: input).bytes == expected)
  }

  @Test(arguments: ["", "GiB", "8XiB", "eight", "8 GiB extra", "-1", "1.2.3GiB", "1.GiB", "8GiiB"])
  func rejectsMalformedInput(input: String) {
    #expect(throws: ByteSize.ParseError.self) { try ByteSize(parsing: input) }
  }

  @Test func rejectsFractionsThatAreNotWholeBytes() {
    #expect(throws: ByteSize.ParseError.self) { try ByteSize(parsing: "1.5B") }
  }

  @Test func rejectsOverflow() {
    #expect(throws: ByteSize.ParseError.self) { try ByteSize(parsing: "99999999PiB") }
  }

  @Test func formattingPicksTheLargestExactUnit() {
    #expect(ByteSize(bytes: 8 << 30).description == "8GiB")
    #expect(ByteSize(bytes: 1536 << 20).description == "1536MiB")
    #expect(ByteSize(bytes: 1023).description == "1023B")
    #expect(ByteSize.zero.description == "0B")
  }

  @Test(arguments: [
    UInt64(0), 1, 1023, 1024, 4096, UInt64(8) << 30, UInt64(80_000_000_000),
    UInt64(1536) << 20, UInt64(120) << 30, 999_983,
  ])
  func formatThenParseIsLossless(bytes: UInt64) throws {
    let size = ByteSize(bytes: bytes)
    #expect(try ByteSize(parsing: size.description) == size)
  }

  @Test func codableUsesTheStringForm() throws {
    let encoded = try JSONEncoder().encode(ByteSize.gibibytes(8))
    #expect(String(decoding: encoded, as: UTF8.self) == "\"8GiB\"")
    #expect(try JSONDecoder().decode(ByteSize.self, from: encoded) == .gibibytes(8))
  }

  @Test func codableRejectsGarbage() {
    let data = Data("\"not-a-size\"".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ByteSize.self, from: data) }
  }

  @Test func comparableOrdersByBytes() {
    #expect(ByteSize.mebibytes(512) < ByteSize.gibibytes(1))
    #expect(ByteSize.gibibytes(1) == ByteSize.mebibytes(1024))
  }
}
