import Foundation
import RunnerCore
import Security

/// The keychain operations `KeychainPATProvider` needs, so the provider can be tested without
/// touching (or unlocking, or prompting for) a real keychain.
public protocol KeychainItemStore: Sendable {
  /// `nil` means "no such item", which is not an error — the chain moves on to the next source.
  func password(service: String, account: String) throws -> Data?
  func setPassword(_ data: Data, service: String, account: String) throws
  func deletePassword(service: String, account: String) throws
}

/// `SecItem*` against the login keychain. Used by `runnerctl auth login|logout` (spec §12).
public struct SecurityKeychainStore: KeychainItemStore {
  public init() {}

  public func password(service: String, account: String) throws -> Data? {
    var query = Self.baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw Self.error(status, operation: "read", service: service, account: account)
    }
  }

  public func setPassword(_ data: Data, service: String, account: String) throws {
    var attributes = Self.baseQuery(service: service, account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "RunnerVM GitHub token"
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = [kSecValueData as String: data] as CFDictionary
      let updateStatus = SecItemUpdate(
        Self.baseQuery(service: service, account: account) as CFDictionary, update
      )
      guard updateStatus == errSecSuccess else {
        throw Self.error(updateStatus, operation: "update", service: service, account: account)
      }
      return
    }
    guard status == errSecSuccess else {
      throw Self.error(status, operation: "write", service: service, account: account)
    }
  }

  public func deletePassword(service: String, account: String) throws {
    let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.error(status, operation: "delete", service: service, account: account)
    }
  }

  private static func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// A locked or non-interactive keychain is an authentication problem an operator must fix; any
  /// other `OSStatus` is a configuration problem. Neither is retryable.
  static func error(
    _ status: OSStatus, operation: String, service: String, account: String
  ) -> GitHubControlError {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    let subject = "keychain item \(service)/\(account)"
    switch status {
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecInteractionRequired:
      return .authenticationFailed(reason: "cannot \(operation) \(subject): \(text)")
    default:
      return .permanentConfiguration(reason: "cannot \(operation) \(subject): \(text) (\(status))")
    }
  }
}

/// PAT held in the macOS Keychain — the preferred development store (spec §12).
public struct KeychainPATProvider: GitHubCredentialProvider {
  public static let defaultService = "com.runnervm.github"

  private let service: String
  private let account: String
  private let keychain: any KeychainItemStore

  public init(
    service: String = KeychainPATProvider.defaultService,
    account: String,
    keychain: any KeychainItemStore = SecurityKeychainStore()
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  public func credential() async throws -> GitHubCredential {
    guard let data = try keychain.password(service: service, account: account) else {
      throw GitHubControlError.notFound(resource: "keychain item \(service)/\(account)")
    }
    guard let raw = String(data: data, encoding: .utf8) else {
      throw GitHubControlError.permanentConfiguration(
        reason: "keychain item \(service)/\(account) is not UTF-8"
      )
    }
    return try GitHubCredential.pat(sanitizing: raw, source: "keychain \(service)/\(account)")
  }

  /// `runnerctl auth login --token-stdin`.
  public func store(token: String) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw GitHubControlError.permanentConfiguration(reason: "refusing to store an empty token")
    }
    try keychain.setPassword(Data(trimmed.utf8), service: service, account: account)
  }

  /// `runnerctl auth logout`. Removing an absent item succeeds.
  public func remove() throws {
    try keychain.deletePassword(service: service, account: account)
  }
}
