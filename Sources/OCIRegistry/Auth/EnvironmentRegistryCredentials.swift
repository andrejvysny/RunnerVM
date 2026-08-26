// Derived from openai/tart@16d186c Sources/tart/Credentials/EnvironmentCredentialsProvider.swift —
// FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation

/// `RUNNERVM_REGISTRY_USERNAME` / `RUNNERVM_REGISTRY_PASSWORD`, optionally pinned to one host with
/// `RUNNERVM_REGISTRY_HOSTNAME`. The intended way to feed a GHCR PAT to a daemon under launchd.
public struct EnvironmentRegistryCredentials: RegistryCredentialProvider {
  public static let usernameKey = "RUNNERVM_REGISTRY_USERNAME"
  public static let passwordKey = "RUNNERVM_REGISTRY_PASSWORD"
  public static let hostnameKey = "RUNNERVM_REGISTRY_HOSTNAME"

  private let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public func credential(for registry: String) async throws -> RegistryCredential? {
    if let pinned = environment[Self.hostnameKey], pinned != registry { return nil }
    guard let username = environment[Self.usernameKey],
          let password = environment[Self.passwordKey],
          !username.isEmpty, !password.isEmpty
    else { return nil }
    return RegistryCredential(username: username, password: password)
  }
}
