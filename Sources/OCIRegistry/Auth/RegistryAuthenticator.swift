// Derived from openai/tart@16d186c Sources/tart/OCI/{Registry.swift:326-441, Authentication.swift,
// AuthenticationKeeper.swift} — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// The Docker registry token flow plus HTTP basic, held per registry host.
///
/// An actor because a concurrent chunk pull will produce several simultaneous 401s: the generation
/// counter collapses them into a single token request instead of one per in-flight blob.
actor RegistryAuthenticator {
  private struct Authorization {
    let headerValue: String
    /// `nil` for basic auth, which never expires on its own.
    let expiresAt: Date?
  }

  /// The token spec's default lifetime when `expires_in` is absent.
  private static let defaultTokenLifetime: TimeInterval = 60
  /// Refresh slightly early: a token that expires mid-upload costs a whole chunk.
  private static let expiryMargin: TimeInterval = 5

  private let registry: String
  private let credentials: any RegistryCredentialProvider
  private let session: URLSession
  private let userAgent: String
  private let now: @Sendable () -> Date
  private let logger: Logger

  private var authorization: Authorization?
  private var generation = 0

  init(
    registry: String, credentials: any RegistryCredentialProvider, session: URLSession,
    userAgent: String, now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .image)
  ) {
    self.registry = registry
    self.credentials = credentials
    self.session = session
    self.userAgent = userAgent
    self.now = now
    self.logger = logger
  }

  /// Current header value, if one is cached and unexpired, with the generation it belongs to.
  func current() -> (headerValue: String?, generation: Int) {
    guard let authorization else { return (nil, generation) }
    if let expiry = authorization.expiresAt, expiry <= now().addingTimeInterval(Self.expiryMargin) {
      return (nil, generation)
    }
    return (authorization.headerValue, generation)
  }

  /// Answers a 401 and returns the header the retry must carry.
  ///
  /// The value is returned rather than re-read through `current()` on purpose: a freshly minted
  /// token is valid even when its lifetime is shorter than the proactive refresh margin.
  func refresh(challenge raw: String?, generation seen: Int, operation: String) async throws -> String? {
    // Another task already replaced the credentials this request was sent with.
    guard seen == generation else { return authorization?.headerValue }
    guard let raw else {
      throw RegistryError.authenticationRequired(
        registry: registry, reason: "HTTP 401 without a WWW-Authenticate header"
      )
    }
    let challenge = try WWWAuthenticate(parsing: raw)
    let credential = try await credentials.credential(for: registry)
    if challenge.isBasic {
      guard let credential else {
        throw RegistryError.authenticationRequired(
          registry: registry, reason: "basic auth required but no credentials are configured"
        )
      }
      store(Authorization(headerValue: credential.basicAuthorizationValue, expiresAt: nil))
      return authorization?.headerValue
    }
    guard challenge.isBearer else {
      throw RegistryError.authenticationRequired(
        registry: registry, reason: "unsupported authentication scheme '\(challenge.scheme)'"
      )
    }
    try await requestToken(challenge: challenge, credential: credential, operation: operation)
    return authorization?.headerValue
  }

  func invalidate() {
    store(nil)
  }

  private func store(_ value: Authorization?) {
    authorization = value
    generation += 1
  }

  // MARK: - Token endpoint

  private func requestToken(
    challenge: WWWAuthenticate, credential: RegistryCredential?, operation: String
  ) async throws {
    guard let realm = challenge.realm, var components = URLComponents(string: realm) else {
      throw RegistryError.authenticationRequired(
        registry: registry, reason: "challenge has no usable realm directive"
      )
    }
    var query = components.queryItems ?? []
    if let service = challenge.service { query.append(URLQueryItem(name: "service", value: service)) }
    if let scope = challenge.scope { query.append(URLQueryItem(name: "scope", value: scope)) }
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else {
      throw RegistryError.authenticationRequired(registry: registry, reason: "malformed realm '\(realm)'")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let credential {
      request.setValue(credential.basicAuthorizationValue, forHTTPHeaderField: "Authorization")
    }

    let (body, head) = try await send(request, operation: operation)
    guard head.status == 200 else {
      let detail = await body.errorDetail()
      throw RegistryError.authenticationRequired(
        registry: registry, reason: "token endpoint returned HTTP \(head.status): \(detail)"
      )
    }
    let payload = try await body.collect(limit: 1 << 20)
    try store(parseToken(payload))
    logger.debug("registry token acquired", metadata: ["registry": .string(registry)])
  }

  private func send(_ request: URLRequest, operation: String) async throws -> (HTTPBody, HTTPResponseHead) {
    do {
      return try await HTTPStreaming.send(request, on: session)
    } catch let error as RegistryError {
      throw error
    } catch {
      throw RegistryError.transport(
        operation: "token request for \(operation)", reason: error.localizedDescription,
        cause: error
      )
    }
  }

  private func parseToken(_ data: Data) throws -> Authorization {
    guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
          let token = response.token ?? response.accessToken, !token.isEmpty
    else {
      throw RegistryError.authenticationRequired(
        registry: registry, reason: "token endpoint returned no token"
      )
    }
    let issued = response.issuedAt.flatMap(Self.parseTimestamp) ?? now()
    let lifetime = TimeInterval(response.expiresIn ?? Int(Self.defaultTokenLifetime))
    return Authorization(headerValue: "Bearer \(token)", expiresAt: issued.addingTimeInterval(lifetime))
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? {
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      return plain.date(from: text)
    }()
  }
}

struct TokenResponse: Decodable {
  var token: String?
  var accessToken: String?
  var expiresIn: Int?
  var issuedAt: String?

  enum CodingKeys: String, CodingKey {
    case token
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case issuedAt = "issued_at"
  }
}
