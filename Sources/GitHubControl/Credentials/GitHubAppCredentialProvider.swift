import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Production credential path (spec §12): sign an app JWT, exchange it for a short-lived
/// installation token, cache that until just before it expires.
///
/// The private key never leaves the host and never reaches a guest (spec §12, §79).
///
/// - Note: implemented in full but not yet exercised against github.com — the JWT structure and
///   the caching are unit-tested, the `POST /app/installations/{id}/access_tokens` round trip is
///   tested only against the in-process fake.
public actor GitHubAppCredentialProvider: GitHubCredentialProvider {
  private let jwt: GitHubAppJWT
  private let installationID: Int64
  private let baseURL: URL
  private let session: URLSession
  private let options: GitHubHTTPClient.Options
  private let logger: Logger
  private let now: @Sendable () -> Date
  private var cached: GitHubCredential?

  public init(
    appID: String,
    installationID: Int64,
    privateKeyPEM: String,
    baseURL: URL = GitHubHTTPClient.defaultBaseURL,
    session: URLSession = .shared,
    options: GitHubHTTPClient.Options = GitHubHTTPClient.Options(),
    logger: Logger = Logger(component: .github),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    jwt = try GitHubAppJWT(appID: appID, privateKeyPEM: privateKeyPEM)
    self.installationID = installationID
    self.baseURL = baseURL
    self.session = session
    self.options = options
    self.logger = logger
    self.now = now
  }

  public func credential() async throws -> GitHubCredential {
    let instant = now()
    if let cached, cached.isValid(at: instant) { return cached }
    let minted = try await mintInstallationToken(at: instant)
    cached = minted
    logger.info(
      "minted GitHub App installation token",
      metadata: [
        "app_id": .string(jwt.appID), "installation_id": .stringConvertible(installationID),
        "expires_at": .string(minted.expiresAt.map(Self.format) ?? "unknown"),
      ]
    )
    return minted
  }

  /// Drops the cached token so the next call mints a fresh one. Used after a 401, which is the
  /// only reliable signal that GitHub revoked an installation early.
  public func invalidate() {
    cached = nil
  }

  private func mintInstallationToken(at instant: Date) async throws -> GitHubCredential {
    let appJWT = try jwt.token(now: instant)
    let client = GitHubHTTPClient(
      baseURL: baseURL,
      credentials: StaticCredentialProvider(token: appJWT, kind: .appJWT),
      session: session,
      options: options,
      logger: logger
    )
    // Minting is safe to repeat: a duplicate token is simply another short-lived credential.
    let request = GitHubRequest.post(
      "/app/installations/\(installationID)/access_tokens", idempotent: true
    )
    let response = try await client.send(request, as: InstallationToken.self)
    let token = response.value.token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw GitHubControlError.authenticationFailed(
        reason: "GitHub returned an empty installation token for installation \(installationID)"
      )
    }
    return GitHubCredential(
      token: token, kind: .installation, expiresAt: Self.parse(response.value.expiresAt)
    )
  }

  private struct InstallationToken: Decodable {
    let token: String
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
      case token
      case expiresAt = "expires_at"
    }
  }

  /// Formatters are built per call: `ISO8601DateFormatter` is a reference type and a shared
  /// static one would need an unchecked-Sendable escape hatch for a once-an-hour code path.
  private static func parse(_ text: String?) -> Date? {
    guard let text else { return nil }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
  }

  private static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
