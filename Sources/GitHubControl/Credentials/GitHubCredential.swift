import Foundation
import RunnerCore

/// A bearer token for api.github.com. The token itself never appears in `description`, so a
/// credential can be interpolated into a log line or an error without leaking (spec §12, §42).
public struct GitHubCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public enum Kind: String, Sendable, Hashable, CaseIterable {
    /// Personal access token — development and single-operator installs.
    case pat
    /// GitHub App installation token, minted from an app JWT and short-lived.
    case installation
    /// The app JWT itself. Only ever used to mint an installation token.
    case appJWT
  }

  public let token: String
  public let kind: Kind
  public let expiresAt: Date?

  public init(token: String, kind: Kind, expiresAt: Date? = nil) {
    self.token = token
    self.kind = kind
    self.expiresAt = expiresAt
  }

  /// Trims the trailing newline a `cat`-ed token file or `--token-stdin` always brings along.
  public static func pat(sanitizing raw: String, source: String) throws -> GitHubCredential {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw GitHubControlError.permanentConfiguration(reason: "\(source) holds an empty token")
    }
    guard !token.contains(where: { $0.isNewline || $0.isWhitespace }) else {
      throw GitHubControlError.permanentConfiguration(
        reason: "\(source) holds whitespace inside the token; it is probably not a PAT"
      )
    }
    return GitHubCredential(token: token, kind: .pat)
  }

  public var authorizationHeader: String {
    "Bearer \(token)"
  }

  /// - Parameter margin: refresh this long before the real expiry so an in-flight request cannot
  ///   be signed with a token that dies mid-flight.
  public func isValid(at instant: Date, margin: Duration = .seconds(60)) -> Bool {
    guard let expiresAt else { return true }
    return instant.addingTimeInterval(Double(margin.components.seconds)) < expiresAt
  }

  public var description: String {
    let expiry = expiresAt.map { " expires \(ISO8601DateFormatter().string(from: $0))" } ?? ""
    return "GitHubCredential(\(kind.rawValue), token: <redacted \(token.utf8.count) bytes>\(expiry))"
  }

  public var debugDescription: String {
    description
  }
}

/// Spec §12: the credential source is abstracted from day one, so switching a deployment from a
/// PAT to a GitHub App touches nothing but wiring.
public protocol GitHubCredentialProvider: Sendable {
  func credential() async throws -> GitHubCredential
}

/// A credential that is already in hand. Used for the app JWT leg of the App flow and in tests.
public struct StaticCredentialProvider: GitHubCredentialProvider {
  private let value: GitHubCredential

  public init(_ value: GitHubCredential) {
    self.value = value
  }

  public init(token: String, kind: GitHubCredential.Kind = .pat) {
    self.init(GitHubCredential(token: token, kind: kind))
  }

  public func credential() async throws -> GitHubCredential {
    value
  }
}
