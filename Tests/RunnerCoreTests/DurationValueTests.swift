import Foundation
import RunnerCore
import Testing

@Suite struct DurationValueTests {
  @Test(arguments: [
    ("30s", Duration.seconds(30)),
    ("20m", Duration.seconds(20 * 60)),
    ("2h", Duration.seconds(2 * 3600)),
    ("1h30m", Duration.seconds(5400)),
    ("7d", Duration.seconds(7 * 86400)),
    ("500ms", Duration.milliseconds(500)),
    ("1h30m15s", Duration.seconds(5415)),
    ("0s", Duration.zero),
    (" 3m ", Duration.seconds(180)),
  ])
  func parsesKnownForms(input: String, expected: Duration) throws {
    #expect(try DurationValue(parsing: input).duration == expected)
  }

  @Test(arguments: ["", "20", "m", "20x", "1h30", "-5s", "1h1h", "1.5h", "s30"])
  func rejectsMalformedInput(input: String) {
    #expect(throws: DurationValue.ParseError.self) { try DurationValue(parsing: input) }
  }

  @Test func rejectsRepeatedUnits() {
    #expect(throws: DurationValue.ParseError.self) { try DurationValue(parsing: "1m1m") }
  }

  @Test func formatsLargestUnitFirstAndSkipsZeroComponents() {
    #expect(DurationValue.seconds(5400).description == "1h30m")
    #expect(DurationValue.minutes(20).description == "20m")
    #expect(DurationValue.hours(2).description == "2h")
    #expect(DurationValue.seconds(30).description == "30s")
    #expect(DurationValue.days(7).description == "7d")
    #expect(DurationValue.zero.description == "0s")
    #expect(DurationValue.milliseconds(1500).description == "1s500ms")
  }

  @Test(arguments: ["30s", "20m", "2h", "1h30m", "7d", "500ms", "1d2h3m4s5ms", "0s"])
  func formatThenParseIsLossless(input: String) throws {
    let value = try DurationValue(parsing: input)
    #expect(try DurationValue(parsing: value.description) == value)
    #expect(value.description == input)
  }

  @Test func codableUsesTheStringForm() throws {
    let encoded = try JSONEncoder().encode(DurationValue.minutes(20))
    #expect(String(decoding: encoded, as: UTF8.self) == "\"20m\"")
    #expect(try JSONDecoder().decode(DurationValue.self, from: encoded) == .minutes(20))
  }

  @Test func codableRejectsGarbage() {
    let data = Data("\"soon\"".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(DurationValue.self, from: data) }
  }

  @Test func bridgesToSwiftDuration() {
    #expect(DurationValue(.seconds(90)).duration == .seconds(90))
    #expect(DurationValue.minutes(2).seconds == 120)
    #expect(DurationValue.zero.isPositive == false)
    #expect(DurationValue.seconds(1).isPositive)
  }

  @Test func comparableOrdersByDuration() {
    #expect(DurationValue.seconds(30) < DurationValue.minutes(1))
    #expect(DurationValue.hours(1) == DurationValue.minutes(60))
  }
}
