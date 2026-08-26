import Foundation
@testable import OCIRegistry
import Testing

struct RegistryAuthenticationTests {
  private static let credential = RegistryCredential(username: "octocat", password: "ghp_secret")

  @Test func anonymousRegistryNeedsNoToken() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    try await fake.makeClient().ping()
    #expect(fake.requests("GET", containing: "/token").isEmpty)
  }

  @Test func bearerFlowExchangesCredentialsForAToken() async throws {
    let fake = FakeRegistry(auth: .bearer(credential: Self.credential))
    defer { fake.shutdown() }
    let client = fake.makeClient(credentials: StaticRegistryCredentials(Self.credential))
    try await client.ping()

    let tokenRequests = fake.requests("GET", containing: "/token")
    #expect(tokenRequests.count == 1)
    #expect(tokenRequests[0].header("Authorization")?.hasPrefix("Basic ") == true)
    // First attempt is unauthenticated and answered with a challenge, then retried with the token.
    let pings = fake.requests("GET", containing: "/v2/")
    #expect(pings.count == 2)
    #expect(pings.last?.header("Authorization")?.hasPrefix("Bearer ") == true)
  }

  @Test func reAuthenticatesWhenTheServerRevokesTheToken() async throws {
    let fake = FakeRegistry(auth: .bearer(credential: Self.credential))
    defer { fake.shutdown() }
    let client = fake.makeClient(credentials: StaticRegistryCredentials(Self.credential))
    try await client.ping()
    fake.expireTokens()
    fake.resetRecording()

    try await client.ping()
    #expect(fake.requests("GET", containing: "/token").count == 1)
    #expect(fake.requests("GET", containing: "/v2/").count == 2)
  }

  @Test func treatsAShortLivedTokenAsAlreadyStale() async throws {
    // Below the refresh margin, so the client never presents the cached token.
    let fake = FakeRegistry(auth: .bearer(credential: nil), tokenLifetime: 1)
    defer { fake.shutdown() }
    let client = fake.makeClient()
    try await client.ping()
    try await client.ping()
    #expect(fake.requests("GET", containing: "/token").count == 2)
  }

  @Test func cachesAnUnexpiredToken() async throws {
    let fake = FakeRegistry(auth: .bearer(credential: nil), tokenLifetime: 3600)
    defer { fake.shutdown() }
    let client = fake.makeClient()
    try await client.ping()
    try await client.ping()
    #expect(fake.requests("GET", containing: "/token").count == 1)
  }

  @Test func basicAuthUsesTheConfiguredCredential() async throws {
    let fake = FakeRegistry(auth: .basic(credential: Self.credential))
    defer { fake.shutdown() }
    let client = fake.makeClient(credentials: StaticRegistryCredentials(Self.credential))
    try await client.ping()
    #expect(fake.requests("GET", containing: "/v2/").last?.header("Authorization")?
      .hasPrefix("Basic ") == true)
  }

  @Test func basicAuthWithoutCredentialsFailsClosed() async throws {
    let fake = FakeRegistry(auth: .basic(credential: Self.credential))
    defer { fake.shutdown() }
    await #expect(throws: RegistryError.self) { try await fake.makeClient().ping() }
  }

  @Test func wrongCredentialsSurfaceAsAnAuthError() async throws {
    let fake = FakeRegistry(auth: .basic(credential: Self.credential))
    defer { fake.shutdown() }
    let wrong = StaticRegistryCredentials(RegistryCredential(username: "octocat", password: "nope"))
    do {
      try await fake.makeClient(credentials: wrong).ping()
      Issue.record("expected an authentication failure")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_AUTH")
      #expect(!error.retryable)
    }
  }

  @Test func credentialDescriptionHidesTheSecret() {
    let text = "\(Self.credential)"
    #expect(text.contains("octocat"))
    #expect(!text.contains("ghp_secret"))
  }
}
