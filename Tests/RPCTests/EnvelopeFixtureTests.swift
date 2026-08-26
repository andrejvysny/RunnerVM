import Foundation
import Testing

@testable import RPC

private struct FixtureFile: Decodable {
  struct Case: Decodable {
    let name: String
    let expect: String
    let reason: String?
    let json: String
  }

  struct Framing: Decodable {
    let name: String
    let expect: String?
    let reason: String?
    let lengthPrefixHex: String
  }

  let cases: [Case]
  let framing: [Framing]
}

private let fixturesURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // RPCTests
  .deletingLastPathComponent()  // Tests
  .deletingLastPathComponent()  // package root
  .appendingPathComponent("Proto/fixtures/envelopes.json")

private func loadFixtures() throws -> FixtureFile {
  try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: fixturesURL))
}

/// The fixture text names the protocol it belongs to; fall back to `guest` for the cases that
/// have no parsable protocol member at all.
private func declaredProtocol(in json: String) -> RPCProtocol {
  for candidate in RPCProtocol.allCases
  where json.contains("\"protocol\":\"\(candidate.rawValue)\"") {
    return candidate
  }
  return .guest
}

@Suite struct EnvelopeFixtureTests {
  @Test func fixtureFileIsPresent() throws {
    let fixtures = try loadFixtures()
    #expect(fixtures.cases.count == 19)
    #expect(fixtures.framing.count == 3)
  }

  @Test func allEnvelopeCasesMatchTheirVerdict() throws {
    for testCase in try loadFixtures().cases {
      let proto = declaredProtocol(in: testCase.json)
      let bytes = Array(testCase.json.utf8)
      do {
        let envelope = try Envelope.decode(from: bytes, expecting: proto)
        #expect(testCase.expect == "valid", "\(testCase.name) unexpectedly decoded")
        let reencoded = try Envelope.decode(from: envelope.encode(), expecting: proto)
        #expect(reencoded == envelope, "\(testCase.name) did not round-trip")
      } catch {
        #expect(testCase.expect == "invalid", "\(testCase.name) failed: \(error.message)")
        #expect(error.code.rawValue == testCase.reason, "\(testCase.name): \(error.message)")
      }
    }
  }

  @Test func int64PayloadsSurviveExactly() throws {
    let json = try loadFixtures().cases.first { $0.name == "big-int64" }!.json
    let envelope = try Envelope.decode(from: Array(json.utf8), expecting: .guest)
    #expect(envelope.payload?["totalBytes"] == .int(9_007_199_254_740_993))
    #expect(String(decoding: envelope.encode(), as: UTF8.self).contains("9007199254740993"))
  }

  @Test func requestIdIsSalvagedFromMalformedEnvelopes() {
    let json = """
      {"protocol":"guest","version":1,"kind":"request","requestId":"r5","method":"a","extra":true}
      """
    #expect(throws: EnvelopeError.self) {
      try Envelope.decode(from: Array(json.utf8), expecting: .guest)
    }
    do {
      _ = try Envelope.decode(from: Array(json.utf8), expecting: .guest)
    } catch {
      #expect(error.requestId == "r5")
      #expect(error.code == .malformed)
    }
  }

  @Test func protocolMismatchIsDistinctFromMalformed() {
    do {
      _ = try Envelope.decode(
        from: Array(#"{"protocol":"guest","version":1,"kind":"cancel","requestId":"r1"}"#.utf8),
        expecting: .daemon)
      Issue.record("expected a mismatch")
    } catch {
      #expect(error.code == .protocolMismatch)
    }
  }

  @Test func encodingIsDeterministicAndSorted() {
    let envelope = Envelope.chunk(
      .worker, requestId: "r1", method: "m", streamSeq: 7, end: false,
      payload: .object(["z": .int(1), "a": .bool(false)]))
    let text = String(decoding: envelope.encode(), as: UTF8.self)
    #expect(
      text == #"{"end":false,"kind":"chunk","method":"m","payload":{"a":false,"z":1},"#
        + #""protocol":"worker","requestId":"r1","streamSeq":7,"version":1}"#)
  }
}
