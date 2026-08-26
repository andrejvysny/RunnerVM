// Derived from openai/tart@16d186c Sources/tart/Credentials/KeychainCredentialsProvider.swift —
// FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import Security

/// A generic internet-password lookup, keyed by registry host.
public protocol KeychainCredentialStore: Sendable {
  func internetPassword(server: String) throws -> RegistryCredential?
}

/// macOS Keychain, `kSecClassInternetPassword` with `kSecAttrServer` = registry host.
public struct KeychainRegistryCredentials: RegistryCredentialProvider {
  public struct Failure: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String {
      "keychain lookup failed with status \(status)"
    }
  }

  private let store: any KeychainCredentialStore

  public init(store: any KeychainCredentialStore = SystemKeychainStore()) {
    self.store = store
  }

  public func credential(for registry: String) async throws -> RegistryCredential? {
    try store.internetPassword(server: registry)
  }
}

public struct SystemKeychainStore: KeychainCredentialStore {
  public init() {}

  public func internetPassword(server: String) throws -> RegistryCredential? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: server,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnAttributes as String: true,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainRegistryCredentials.Failure(status: status) }
    guard let attributes = item as? [String: Any],
          let username = attributes[kSecAttrAccount as String] as? String,
          let data = attributes[kSecValueData as String] as? Data,
          let password = String(data: data, encoding: .utf8)
    else {
      throw KeychainRegistryCredentials.Failure(status: errSecDecode)
    }
    return RegistryCredential(username: username, password: password)
  }
}
