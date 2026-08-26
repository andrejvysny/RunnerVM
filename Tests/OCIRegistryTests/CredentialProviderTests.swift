import Foundation
@testable import OCIRegistry
import Testing

struct CredentialProviderTests {
  @Test func environmentProviderReadsTheDocumentedVariables() async throws {
    let provider = EnvironmentRegistryCredentials(environment: [
      EnvironmentRegistryCredentials.usernameKey: "octocat",
      EnvironmentRegistryCredentials.passwordKey: "ghp_secret",
    ])
    #expect(try await provider.credential(for: "ghcr.io")?.username == "octocat")
  }

  @Test func environmentProviderHonoursTheHostnamePin() async throws {
    let provider = EnvironmentRegistryCredentials(environment: [
      EnvironmentRegistryCredentials.usernameKey: "octocat",
      EnvironmentRegistryCredentials.passwordKey: "ghp_secret",
      EnvironmentRegistryCredentials.hostnameKey: "ghcr.io",
    ])
    #expect(try await provider.credential(for: "ghcr.io") != nil)
    #expect(try await provider.credential(for: "registry.example.com") == nil)
  }

  @Test func dockerConfigDecodesInlineBase64Auth() async throws {
    let temp = try TempDirectory("docker-config")
    let config = temp.appending("config.json")
    let auth = Data("octocat:ghp_secret".utf8).base64EncodedString()
    try Data(#"{"auths":{"ghcr.io":{"auth":"\#(auth)"}}}"#.utf8).write(to: config)

    let provider = DockerConfigCredentials(configURL: config) { _, _ in Data() }
    let credential = try await provider.credential(for: "ghcr.io")
    #expect(credential == RegistryCredential(username: "octocat", password: "ghp_secret"))
  }

  @Test func dockerConfigAcceptsAURLStyleAuthKey() async throws {
    let temp = try TempDirectory("docker-config-url")
    let config = temp.appending("config.json")
    let auth = Data("u:p".utf8).base64EncodedString()
    try Data(#"{"auths":{"https://index.example.com/v1/":{"auth":"\#(auth)"}}}"#.utf8).write(to: config)

    let provider = DockerConfigCredentials(configURL: config) { _, _ in Data() }
    #expect(try await provider.credential(for: "index.example.com")?.password == "p")
  }

  @Test func dockerConfigFallsBackToACredentialHelper() async throws {
    let temp = try TempDirectory("docker-helpers")
    let config = temp.appending("config.json")
    try Data(#"{"credHelpers":{"ghcr.io":"test"},"credsStore":"other"}"#.utf8).write(to: config)

    let provider = DockerConfigCredentials(configURL: config) { helper, registry in
      #expect(helper == "test")
      #expect(registry == "ghcr.io")
      return Data(#"{"Username":"octocat","Secret":"helper-secret"}"#.utf8)
    }
    #expect(try await provider.credential(for: "ghcr.io")?.password == "helper-secret")
  }

  @Test func dockerConfigUsesCredsStoreWhenNoHostMatches() async throws {
    let temp = try TempDirectory("docker-credsstore")
    let config = temp.appending("config.json")
    try Data(#"{"credsStore":"osxkeychain"}"#.utf8).write(to: config)

    let provider = DockerConfigCredentials(configURL: config) { helper, _ in
      #expect(helper == "osxkeychain")
      return Data(#"{"Username":"u","Secret":"s"}"#.utf8)
    }
    #expect(try await provider.credential(for: "ghcr.io")?.username == "u")
  }

  @Test func dockerConfigIsSilentWhenTheFileIsAbsent() async throws {
    let temp = try TempDirectory("docker-missing")
    let provider = DockerConfigCredentials(configURL: temp.appending("nope.json")) { _, _ in Data() }
    #expect(try await provider.credential(for: "ghcr.io") == nil)
  }

  @Test func keychainProviderForwardsToItsStore() async throws {
    struct Store: KeychainCredentialStore {
      func internetPassword(server: String) throws -> RegistryCredential? {
        server == "ghcr.io" ? RegistryCredential(username: "keychain", password: "k") : nil
      }
    }
    let provider = KeychainRegistryCredentials(store: Store())
    #expect(try await provider.credential(for: "ghcr.io")?.username == "keychain")
    #expect(try await provider.credential(for: "other.io") == nil)
  }

  @Test func chainSkipsAProviderThatThrows() async throws {
    struct Broken: RegistryCredentialProvider {
      struct Boom: Error {}
      func credential(for registry: String) async throws -> RegistryCredential? {
        throw Boom()
      }
    }
    let chain = ChainedRegistryCredentials([
      Broken(),
      StaticRegistryCredentials(RegistryCredential(username: "second", password: "s")),
    ])
    #expect(try await chain.credential(for: "ghcr.io")?.username == "second")
  }

  @Test func chainReturnsNothingWhenNoProviderAnswers() async throws {
    let chain = ChainedRegistryCredentials([AnonymousRegistryCredentials()])
    #expect(try await chain.credential(for: "ghcr.io") == nil)
  }
}

/// Mutates `PATH`, so it must not run next to anything else that resolves an executable.
@Suite(.serialized) struct DockerCredentialHelperSubprocessTests {
  @Test func runsARealDockerCredentialHelperFromPATH() async throws {
    let temp = try TempDirectory("helper-bin")
    let helper = temp.appending("docker-credential-runnervmtest")
    let script = """
    #!/bin/sh
    read -r host
    printf '{"Username":"%s-user","Secret":"shell-secret"}' "$host"
    """
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false)
    )

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", "\(temp.url.path(percentEncoded: false)):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }

    let config = temp.appending("config.json")
    try Data(#"{"credHelpers":{"ghcr.io":"runnervmtest"}}"#.utf8).write(to: config)

    let provider = DockerConfigCredentials(configURL: config)
    let credential = try await provider.credential(for: "ghcr.io")
    #expect(credential == RegistryCredential(username: "ghcr.io-user", password: "shell-secret"))
  }

  @Test func reportsAMissingHelper() async throws {
    let temp = try TempDirectory("helper-missing")
    let config = temp.appending("config.json")
    try Data(#"{"credHelpers":{"ghcr.io":"definitely-not-installed"}}"#.utf8).write(to: config)
    let provider = DockerConfigCredentials(configURL: config)
    await #expect(throws: DockerConfigCredentials.HelperFailure.self) {
      try await provider.credential(for: "ghcr.io")
    }
  }
}
