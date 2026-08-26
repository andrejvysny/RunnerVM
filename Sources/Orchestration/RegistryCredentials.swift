import Foundation
import Logging
import OCIRegistry
import RunnerCore
import RunnerLogging
import Security

/// A Keychain call that did not return `errSecSuccess`.
///
/// `OCIRegistry.KeychainRegistryCredentials.Failure` would be the natural type, but its memberwise
/// initializer is internal to that module, so the write path carries its own.
public struct RegistryKeychainError: Error, CustomStringConvertible, Sendable {
  public let status: OSStatus
  public init(status: OSStatus) { self.status = status }
  public var description: String { "keychain operation failed with status \(status)" }
}

/// A keychain the daemon can write to, not just read from.
///
/// `OCIRegistry.KeychainCredentialStore` is read-only because pulling never needs to write; the
/// two mutating halves live here because `runnerctl registry login|logout` is a daemon-side
/// operation (spec §79: the daemon owns the credential, the CLI only carries it over the socket).
public protocol RegistryCredentialStore: KeychainCredentialStore {
  func store(_ credential: RegistryCredential, server: String) throws
  /// `false` when nothing was stored — logout is idempotent.
  @discardableResult
  func remove(server: String) throws -> Bool
}

/// macOS Keychain, `kSecClassInternetPassword` keyed by registry host — the same item
/// `OCIRegistry.SystemKeychainStore` reads, so a login here is immediately visible to a pull.
public struct SystemRegistryKeychain: RegistryCredentialStore {
  private let reader = SystemKeychainStore()

  public init() {}

  public func internetPassword(server: String) throws -> RegistryCredential? {
    try reader.internetPassword(server: server)
  }

  public func store(_ credential: RegistryCredential, server: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: server,
    ]
    let attributes: [String: Any] = [
      kSecAttrAccount as String: credential.username,
      kSecValueData as String: Data(credential.password.utf8),
    ]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw RegistryKeychainError(status: updated) }
    let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    guard added == errSecSuccess else { throw RegistryKeychainError(status: added) }
  }

  @discardableResult
  public func remove(server: String) throws -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: server,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw RegistryKeychainError(status: status) }
    return true
  }
}

/// The daemon's registry credential chain, plus the per-provider view `registry.status` reports.
///
/// `ChainedRegistryCredentials` deliberately hides which provider answered — that is the right
/// behaviour for a pull, and the wrong one for an operator asking "will this registry work?", so
/// the providers are kept individually addressable here.
public struct RegistryCredentials: Sendable {
  /// Provider names as `registry.status` reports them. Order is the resolution order.
  public enum Provider: String, Sendable, CaseIterable {
    case environment
    case dockerConfig
    case keychain
  }

  public let keychain: any RegistryCredentialStore
  private let environment: EnvironmentRegistryCredentials
  private let dockerConfig: DockerConfigCredentials
  private let logger: Logger

  public init(
    keychain: any RegistryCredentialStore = SystemRegistryKeychain(),
    environment: EnvironmentRegistryCredentials = EnvironmentRegistryCredentials(),
    dockerConfig: DockerConfigCredentials = DockerConfigCredentials(),
    logger: Logger = Logger(component: .image)
  ) {
    self.keychain = keychain
    self.environment = environment
    self.dockerConfig = dockerConfig
    self.logger = logger
  }

  /// env → `~/.docker/config.json` → Keychain, matching `ChainedRegistryCredentials.standard()`
  /// but bound to this instance's (possibly injected) keychain.
  public func chain() -> ChainedRegistryCredentials {
    ChainedRegistryCredentials(
      [environment, dockerConfig, KeychainRegistryCredentials(store: keychain)], logger: logger)
  }

  /// Which provider would answer for `registry`, and under which username. Never returns, logs or
  /// otherwise exposes the password.
  public func probe(registry: String) async -> (provider: Provider, username: String)? {
    let ordered: [(Provider, any RegistryCredentialProvider)] = [
      (.environment, environment),
      (.dockerConfig, dockerConfig),
      (.keychain, KeychainRegistryCredentials(store: keychain)),
    ]
    for (provider, source) in ordered {
      guard let credential = try? await source.credential(for: registry) else { continue }
      return (provider, credential.username)
    }
    return nil
  }
}

/// How `ImageManager` obtains a client for a registry host. Injected so tests can hand back a
/// `FakeRegistry`-backed client without a socket or a real host.
public protocol RegistryClientFactory: Sendable {
  func client(for registry: String) async throws -> RegistryClient
}

/// Production factory: one `URLSession`-backed client per call, sharing one credential chain.
public struct DefaultRegistryClientFactory: RegistryClientFactory {
  private let credentials: any RegistryCredentialProvider
  private let options: RegistryClient.Options
  private let logger: Logger

  public init(
    credentials: any RegistryCredentialProvider,
    options: RegistryClient.Options = RegistryClient.Options(),
    logger: Logger = Logger(component: .image)
  ) {
    self.credentials = credentials
    self.options = options
    self.logger = logger
  }

  public func client(for registry: String) async throws -> RegistryClient {
    RegistryClient(registry: registry, credentials: credentials, options: options, logger: logger)
  }
}
