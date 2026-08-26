import Foundation
import RunnerCore

/// `RUNNERVM_GITHUB_TOKEN` — local development and tests only (spec §12).
public struct EnvironmentPATProvider: GitHubCredentialProvider {
  public static let defaultVariable = "RUNNERVM_GITHUB_TOKEN"

  private let variable: String
  private let environment: [String: String]

  public init(
    variable: String = EnvironmentPATProvider.defaultVariable,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.variable = variable
    self.environment = environment
  }

  public func credential() async throws -> GitHubCredential {
    guard let raw = environment[variable] else {
      throw GitHubControlError.notFound(resource: "environment variable \(variable)")
    }
    return try GitHubCredential.pat(sanitizing: raw, source: variable)
  }
}

/// A token in a file. The file must be readable by its owner only: a PAT with `admin:org` in a
/// world-readable file is a host-wide compromise, so a wrong mode is a configuration error rather
/// than a warning (spec §12, §79).
public struct FilePATProvider: GitHubCredentialProvider {
  private let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func credential() async throws -> GitHubCredential {
    let path = url.path(percentEncoded: false)
    let raw = try SecureFile.readString(path: path, label: "token file", policy: .ownerOnly)
    return try GitHubCredential.pat(sanitizing: raw, source: "token file \(path)")
  }
}

/// Tries each source in order and returns the first token. A source that simply has nothing to
/// offer is skipped; a source that is *present but broken* (wrong file mode, locked keychain) is
/// reported, because silently falling through would hide a misconfiguration until the first job.
public struct ChainedCredentialProvider: GitHubCredentialProvider {
  private let providers: [any GitHubCredentialProvider]

  public init(_ providers: [any GitHubCredentialProvider]) {
    self.providers = providers
  }

  public func credential() async throws -> GitHubCredential {
    var absent = 0
    for provider in providers {
      do {
        return try await provider.credential()
      } catch let error as GitHubControlError where error.errorClass == .notFound {
        absent += 1
      }
    }
    throw GitHubControlError.authenticationFailed(
      reason: "no GitHub credential source produced a token (\(absent) source(s) had none)"
    )
  }
}
