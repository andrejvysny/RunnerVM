import Foundation
import RunnerCore
import Testing

@Suite struct ImageReferenceTests {
  static let digest = "sha256:" + String(repeating: "ab", count: 32)

  @Test func parsesRegistryPathAndTag() throws {
    let reference = try ImageReference(parsing: "ghcr.io/acme/runnervm/ubuntu-24:stable")
    #expect(reference.registry == "ghcr.io")
    #expect(reference.repository == "acme/runnervm/ubuntu-24")
    #expect(reference.tag == "stable")
    #expect(reference.digest == nil)
    #expect(reference.description == "ghcr.io/acme/runnervm/ubuntu-24:stable")
  }

  @Test func parsesDigestForm() throws {
    let reference = try ImageReference(parsing: "ghcr.io/acme/ubuntu-24@\(Self.digest)")
    #expect(reference.tag == nil)
    #expect(reference.digest?.rawValue == Self.digest)
  }

  @Test func parsesTagAndDigestTogether() throws {
    let reference = try ImageReference(parsing: "ghcr.io/acme/ubuntu-24:stable@\(Self.digest)")
    #expect(reference.tag == "stable")
    #expect(reference.digest?.rawValue == Self.digest)
    #expect(reference.description == "ghcr.io/acme/ubuntu-24:stable@\(Self.digest)")
  }

  @Test func parsesRegistryWithPort() throws {
    let reference = try ImageReference(parsing: "localhost:5000/acme/ubuntu-24:dev")
    #expect(reference.registry == "localhost:5000")
    #expect(reference.repository == "acme/ubuntu-24")
  }

  @Test(arguments: [
    "ubuntu-24",
    "ubuntu-24:stable",
    "acme/ubuntu-24:stable",
    "ghcr.io/acme/UPPER",
    "ghcr.io/acme/ubuntu-24:",
    "ghcr.io/acme/ubuntu-24@sha256:zz",
    "ghcr.io/acme/ubuntu-24@md5:abc",
    "ghcr.io/acme//ubuntu-24",
    "ghcr.io/",
    "/acme/ubuntu",
    "-bad.io/acme/ubuntu",
    "ghcr.io/acme/-ubuntu",
    "",
  ])
  func rejectsMalformedReferences(text: String) {
    #expect(!ImageReference.isValid(text), "\(text)")
    #expect(throws: ImageReference.ParseError.self) { try ImageReference(parsing: text) }
  }

  @Test func rejectsUppercaseHexInDigest() {
    #expect(!ImageReference.isValid("ghcr.io/acme/x@sha256:" + String(repeating: "AB", count: 32)))
  }

  @Test func codableUsesTheCanonicalString() throws {
    let reference = try ImageReference(parsing: "ghcr.io/acme/ubuntu-24:stable")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(reference)
    #expect(String(decoding: data, as: UTF8.self) == "\"ghcr.io/acme/ubuntu-24:stable\"")
    #expect(try JSONDecoder().decode(ImageReference.self, from: data) == reference)
  }

  @Test func codableRejectsGarbage() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ImageReference.self, from: Data("\"nope\"".utf8))
    }
  }
}
