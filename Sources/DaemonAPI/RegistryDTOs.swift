import Foundation

// MARK: - registry.*

/// Spec §79. The password travels over `runnerd.sock` (peer-UID checked, 0700 directory) straight
/// into the daemon's Keychain; it is never echoed back, logged or written to the applied YAML.
public struct RegistryLoginRequest: Codable, Sendable, Hashable {
  /// Registry host including a non-default port: `ghcr.io`, `localhost:5000`.
  public var registry: String
  public var username: String
  public var password: String

  public init(registry: String, username: String, password: String) {
    self.registry = registry
    self.username = username
    self.password = password
  }
}

public struct RegistryLoginResponse: Codable, Sendable, Hashable {
  public var registry: String
  public var username: String
  /// Human description of where the credential landed, e.g. `keychain ghcr.io`.
  public var location: String

  public init(registry: String, username: String, location: String) {
    self.registry = registry
    self.username = username
    self.location = location
  }
}

public struct RegistryLogoutRequest: Codable, Sendable, Hashable {
  public var registry: String

  public init(registry: String) { self.registry = registry }
}

public struct RegistryLogoutResponse: Codable, Sendable, Hashable {
  public var registry: String
  /// `false` when there was nothing stored — logout is idempotent.
  public var removed: Bool

  public init(registry: String, removed: Bool) {
    self.registry = registry
    self.removed = removed
  }
}

/// One registry a profile points at, and which credential provider would answer for it.
public struct RegistryCredentialDTO: Codable, Sendable, Hashable {
  public var registry: String
  /// `environment`, `dockerConfig` or `keychain`; `nil` means pulls will be anonymous.
  public var provider: String?
  /// Username the provider reports. The password is never returned.
  public var username: String?
  /// Profiles whose `image:` names this registry.
  public var profiles: [String]

  public init(registry: String, provider: String?, username: String?, profiles: [String]) {
    self.registry = registry
    self.provider = provider
    self.username = username
    self.profiles = profiles
  }
}

/// Offline: reports what the credential chain holds, never what a registry thinks of it.
public struct RegistryStatusResponse: Codable, Sendable, Hashable {
  public var registries: [RegistryCredentialDTO]

  public init(registries: [RegistryCredentialDTO]) { self.registries = registries }
}
