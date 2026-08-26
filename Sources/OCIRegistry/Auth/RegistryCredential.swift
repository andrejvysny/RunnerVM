import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// A registry username/password pair. GHCR PATs and GitHub App package tokens both arrive here as
/// the password (spec §79); nothing in this module ever accepts an Actions control-plane token.
public struct RegistryCredential: Sendable, Hashable, CustomStringConvertible {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }

  /// Deliberately lossy: credentials end up in error messages and log metadata.
  public var description: String {
    "RegistryCredential(username: \(username), password: <redacted>)"
  }

  var basicAuthorizationValue: String {
    "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
  }
}

/// Registry auth is resolved per host, never per repository: a token is scoped by the registry's own
/// token service, not by us (spec §79).
public protocol RegistryCredentialProvider: Sendable {
  /// - Parameter registry: host, including a non-default port (`ghcr.io`, `localhost:5000`).
  func credential(for registry: String) async throws -> RegistryCredential?
}

/// Fixed credentials, optionally pinned to one host. Used by `runnerctl registry login --stdin`
/// and by tests.
public struct StaticRegistryCredentials: RegistryCredentialProvider {
  private let credential: RegistryCredential
  private let registry: String?

  public init(_ credential: RegistryCredential, registry: String? = nil) {
    self.credential = credential
    self.registry = registry
  }

  public func credential(for registry: String) async throws -> RegistryCredential? {
    guard self.registry == nil || self.registry == registry else { return nil }
    return credential
  }
}

/// First provider that answers wins. A provider that throws is logged and skipped: a broken
/// credential helper must not make an anonymous pull of a public image fail.
public struct ChainedRegistryCredentials: RegistryCredentialProvider {
  private let providers: [any RegistryCredentialProvider]
  private let logger: Logger

  public init(_ providers: [any RegistryCredentialProvider], logger: Logger = Logger(component: .image)) {
    self.providers = providers
    self.logger = logger
  }

  /// env → `~/.docker/config.json` → Keychain, matching what `docker login` users already have.
  public static func standard(logger: Logger = Logger(component: .image)) -> ChainedRegistryCredentials {
    ChainedRegistryCredentials(
      [EnvironmentRegistryCredentials(), DockerConfigCredentials(), KeychainRegistryCredentials()],
      logger: logger
    )
  }

  public func credential(for registry: String) async throws -> RegistryCredential? {
    for provider in providers {
      do {
        if let credential = try await provider.credential(for: registry) { return credential }
      } catch {
        logger.warning(
          "registry credential provider failed",
          metadata: ["provider": .string("\(type(of: provider))"), "error": .string("\(error)")]
        )
      }
    }
    return nil
  }
}

/// No credentials at all: anonymous pulls of public repositories still work through the token flow.
public struct AnonymousRegistryCredentials: RegistryCredentialProvider {
  public init() {}
  public func credential(for registry: String) async throws -> RegistryCredential? {
    nil
  }
}
