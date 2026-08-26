import Foundation
@testable import GitHubControl
import RunnerCore
import Security
import Synchronization
import Testing

/// In-memory `KeychainItemStore`, so the provider is tested without unlocking — or prompting for —
/// a real keychain.
final class FakeKeychain: KeychainItemStore {
  private let items = Mutex<[String: Data]>([:])
  private let failure: GitHubControlError?

  init(failure: GitHubControlError? = nil) {
    self.failure = failure
  }

  func password(service: String, account: String) throws -> Data? {
    if let failure { throw failure }
    return items.withLock { $0["\(service)/\(account)"] }
  }

  func setPassword(_ data: Data, service: String, account: String) throws {
    if let failure { throw failure }
    items.withLock { $0["\(service)/\(account)"] = data }
  }

  func deletePassword(service: String, account: String) throws {
    if let failure { throw failure }
    items.withLock { $0["\(service)/\(account)"] = nil }
  }
}

struct CredentialProviderTests {
  // MARK: - Environment (spec §12)

  @Test func readsTokenFromTheEnvironment() async throws {
    let provider = EnvironmentPATProvider(environment: ["RUNNERVM_GITHUB_TOKEN": "\(Fixture.token)\n"])
    let credential = try await provider.credential()
    #expect(credential.token == Fixture.token)
    #expect(credential.kind == .pat)
    #expect(credential.expiresAt == nil)
  }

  @Test func missingEnvironmentVariableIsNotFound() async throws {
    let error = await captureError { _ = try await EnvironmentPATProvider(environment: [:]).credential() }
    try #expect(try errorClass(of: #require(error)) == .notFound)
  }

  @Test func emptyEnvironmentTokenIsAConfigurationError() async throws {
    let provider = EnvironmentPATProvider(environment: ["RUNNERVM_GITHUB_TOKEN": "   \n"])
    let error = await captureError { _ = try await provider.credential() }
    try #expect(try errorClass(of: #require(error)) == .permanentConfiguration)
  }

  // MARK: - File

  @Test func readsTokenFromAnOwnerOnlyFile() async throws {
    try await withTokenFile(mode: 0o600) { url in
      let credential = try await FilePATProvider(url: url).credential()
      #expect(credential.token == Fixture.token)
    }
  }

  @Test func rejectsAWorldReadableTokenFile() async throws {
    try await withTokenFile(mode: 0o644) { url in
      let error = await captureError { _ = try await FilePATProvider(url: url).credential() }
      let captured = try #require(error) as? GitHubControlError
      #expect(captured?.errorClass == .permanentConfiguration)
      #expect(captured?.message.contains("644") == true)
    }
  }

  @Test func missingTokenFileIsNotFound() async throws {
    let url = URL(filePath: "/nonexistent/runnervm/token")
    let error = await captureError { _ = try await FilePATProvider(url: url).credential() }
    try #expect(try errorClass(of: #require(error)) == .notFound)
  }

  // MARK: - Chain

  @Test func chainSkipsAbsentSourcesAndReturnsTheFirstToken() async throws {
    try await withTokenFile(mode: 0o600) { url in
      let chain = ChainedCredentialProvider([
        EnvironmentPATProvider(environment: [:]),
        FilePATProvider(url: url),
        EnvironmentPATProvider(environment: ["RUNNERVM_GITHUB_TOKEN": "never-reached"]),
      ])
      try #expect(try await chain.credential().token == Fixture.token)
    }
  }

  @Test func chainSurfacesABrokenSourceRatherThanFallingThrough() async throws {
    try await withTokenFile(mode: 0o644) { url in
      let chain = ChainedCredentialProvider([
        FilePATProvider(url: url),
        EnvironmentPATProvider(environment: ["RUNNERVM_GITHUB_TOKEN": Fixture.token]),
      ])
      let error = await captureError { _ = try await chain.credential() }
      try #expect(try errorClass(of: #require(error)) == .permanentConfiguration)
    }
  }

  @Test func exhaustedChainFailsAuthentication() async throws {
    let chain = ChainedCredentialProvider([EnvironmentPATProvider(environment: [:])])
    let error = await captureError { _ = try await chain.credential() }
    try #expect(try errorClass(of: #require(error)) == .authentication)
  }

  // MARK: - Keychain (spec §12)

  @Test func keychainProviderRoundTripsAToken() async throws {
    let provider = KeychainPATProvider(account: "acme", keychain: FakeKeychain())
    let missing = await captureError { _ = try await provider.credential() }
    try #expect(try errorClass(of: #require(missing)) == .notFound)

    try provider.store(token: "\(Fixture.token)\n")
    try #expect(try await provider.credential().token == Fixture.token)

    try provider.remove()
    let removed = await captureError { _ = try await provider.credential() }
    try #expect(try errorClass(of: #require(removed)) == .notFound)
  }

  @Test func keychainProviderRefusesAnEmptyToken() throws {
    let provider = KeychainPATProvider(account: "acme", keychain: FakeKeychain())
    #expect(throws: GitHubControlError.self) { try provider.store(token: "  ") }
  }

  @Test func lockedKeychainIsAnAuthenticationProblem() {
    let error = SecurityKeychainStore.error(
      errSecInteractionNotAllowed, operation: "read", service: "s", account: "a"
    )
    #expect(error.errorClass == .authentication)
    let other = SecurityKeychainStore.error(
      errSecParam, operation: "read", service: "s", account: "a"
    )
    #expect(other.errorClass == .permanentConfiguration)
  }

  /// The real keychain is opt-in: an unattended `swift test` must never risk an access prompt.
  @Test func realKeychainRoundTripWhenOptedIn() async throws {
    guard ProcessInfo.processInfo.environment["RUNNERVM_KEYCHAIN_TESTS"] == "1" else { return }
    let provider = KeychainPATProvider(
      service: "com.runnervm.github.tests", account: UUID().uuidString
    )
    try provider.store(token: Fixture.token)
    try #expect(try await provider.credential().token == Fixture.token)
    try provider.remove()
  }

  // MARK: - Redaction (spec §42, §36)

  @Test func credentialAndJITConfigNeverPrintTheirSecret() {
    let credential = GitHubCredential(token: Fixture.token, kind: .installation, expiresAt: Fixture.now)
    #expect(!credential.description.contains(Fixture.token))
    #expect(!"\(credential)".contains(Fixture.token))
    #expect(credential.description.contains("redacted"))

    let config = JITRunnerConfig(
      runnerID: 1, runnerName: "runnervm-1", encodedJITConfig: "eyJzZWNyZXQiOiJ2YWx1ZSJ9"
    )
    #expect(!config.description.contains("eyJzZWNyZXQiOiJ2YWx1ZSJ9"))
    #expect(!config.debugDescription.contains("eyJzZWNyZXQiOiJ2YWx1ZSJ9"))
    #expect(config.description.contains("runnervm-1"))
  }

  @Test func credentialExpiryLeavesAMargin() {
    let credential = GitHubCredential(
      token: "x", kind: .installation, expiresAt: Fixture.now.addingTimeInterval(30)
    )
    #expect(!credential.isValid(at: Fixture.now))
    #expect(credential.isValid(at: Fixture.now, margin: .seconds(10)))
    #expect(GitHubCredential(token: "x", kind: .pat).isValid(at: Fixture.now))
  }

  // MARK: - Helpers

  private func withTokenFile(mode: Int, _ body: (URL) async throws -> Void) async throws {
    let directory = URL.temporaryDirectory.appending(path: "runnervm-token-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "token")
    try Data("\(Fixture.token)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    try await body(url)
  }
}
