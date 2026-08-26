import Foundation
@testable import OCIRegistry
import Testing

struct WWWAuthenticateTests {
  @Test func parsesABearerChallenge() throws {
    let header = try WWWAuthenticate(
      parsing: #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:a/b:pull""#
    )
    #expect(header.isBearer)
    #expect(header.realm == "https://ghcr.io/token")
    #expect(header.service == "ghcr.io")
    #expect(header.scope == "repository:a/b:pull")
  }

  @Test func keepsCommasInsideAQuotedScope() throws {
    let header = try WWWAuthenticate(
      parsing: #"Bearer realm="https://r/token",scope="repository:a/b:pull,push",service="r""#
    )
    #expect(header.scope == "repository:a/b:pull,push")
    #expect(header.service == "r")
  }

  @Test func parsesBasicAndLowercasesDirectiveNames() throws {
    let header = try WWWAuthenticate(parsing: #"Basic Realm="registry""#)
    #expect(header.isBasic)
    #expect(header.realm == "registry")
  }

  @Test func acceptsASchemeWithoutDirectives() throws {
    #expect(try WWWAuthenticate(parsing: "Negotiate").directives.isEmpty)
  }

  @Test func rejectsMalformedDirectives() {
    #expect(throws: RegistryError.self) { try WWWAuthenticate(parsing: "Bearer realm") }
    #expect(throws: RegistryError.self) { try WWWAuthenticate(parsing: "  ") }
  }
}
