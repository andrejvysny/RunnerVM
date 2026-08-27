// Ported from github.com/actions/scaleset@v0.4.0 (MIT) client.go, common_client.go, config.go
// — see PROVENANCE.md.

import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Identifies the client to the Actions service. Serialised as the `User-Agent` JSON document the
/// service expects (`{"system":…,"version":…,"commit_sha":…,"scale_set_id":…,"subsystem":…}`).
public struct ActionsSystemInfo: Codable, Sendable, Hashable {
  public var system: String
  public var version: String
  public var commitSHA: String
  public var scaleSetID: Int
  public var subsystem: String

  public init(
    system: String = "runnervm", version: String = "0.1.0-dev", commitSHA: String = "unknown",
    scaleSetID: Int = 0, subsystem: String = "runnerd"
  ) {
    self.system = system
    self.version = version
    self.commitSHA = commitSHA
    self.scaleSetID = scaleSetID
    self.subsystem = subsystem
  }

  private enum CodingKeys: String, CodingKey {
    case system, version, subsystem
    case commitSHA = "commit_sha"
    case scaleSetID = "scale_set_id"
  }

  /// The exact document the Go client sends, including the `kind` discriminator the service logs.
  var userAgent: String {
    let document = UserAgentDocument(info: self)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8)
    else { return "runnervm" }
    return text
  }
}

/// The `User-Agent` payload: the system info plus the build fields and the `kind` discriminator
/// the Actions service uses to tell scale-set clients apart.
private struct UserAgentDocument: Encodable {
  let system: String
  let version: String
  let commitSHA: String
  let scaleSetID: Int
  let subsystem: String
  let buildVersion: String
  let buildCommitSHA: String
  let kind = "scaleset"

  init(info: ActionsSystemInfo) {
    system = info.system
    version = info.version
    commitSHA = info.commitSHA
    scaleSetID = info.scaleSetID
    subsystem = info.subsystem
    buildVersion = info.version
    buildCommitSHA = info.commitSHA
  }

  private enum CodingKeys: String, CodingKey {
    case system, version, subsystem, kind
    case commitSHA = "commit_sha"
    case scaleSetID = "scale_set_id"
    case buildVersion = "build_version"
    case buildCommitSHA = "build_commit_sha"
  }
}

/// Tunables shared by the scale-set client and its message sessions.
public struct ActionsServiceOptions: Sendable, Hashable {
  /// Query parameter added to every Actions-service request.
  public var apiVersion: String
  /// Per-attempt deadline for everything except the message-queue long poll.
  public var requestTimeout: Duration
  /// Long-poll deadline. Floored at 60 s: the service holds the request for ~50 s before
  /// answering 202, so anything shorter turns every idle poll into a transport error.
  public var pollTimeout: Duration
  /// Refresh the admin JWT this long before its `exp`.
  public var tokenRefreshMargin: Duration
  public var retryPolicy: RetryPolicy

  public init(
    apiVersion: String = "6.0-preview", requestTimeout: Duration = .seconds(30),
    pollTimeout: Duration = .seconds(75), tokenRefreshMargin: Duration = .seconds(60),
    retryPolicy: RetryPolicy = .github
  ) {
    self.apiVersion = apiVersion
    self.requestTimeout = requestTimeout
    self.pollTimeout = pollTimeout
    self.tokenRefreshMargin = tokenRefreshMargin
    self.retryPolicy = retryPolicy
  }

  var effectivePollTimeout: Duration {
    max(pollTimeout, .seconds(60))
  }
}

/// Retry loop shared by the client and its sessions. `sleep`/`random` are injected so tests spend
/// no wall-clock time.
struct ActionsRetry: Sendable {
  var policy: RetryPolicy
  var sleep: @Sendable (Duration) async throws -> Void
  var random: @Sendable (ClosedRange<Double>) -> Double
  var logger = Logger(component: .github)

  func run<T: Sendable>(
    idempotent: Bool, _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let logger = logger
    return try await policy.run(
      sleep: sleep, random: random,
      retryAfter: { ($0 as? GitHubControlError)?.retryAfter },
      shouldRetry: { error in
        guard idempotent, let error = error as? GitHubControlError, error.retryable else {
          return false
        }
        // Retries against the Actions service are otherwise silent; a registration that stalls
        // for minutes at daemon start has to be visible in the log.
        logger.warning(
          "Actions service request failed; retrying",
          metadata: ["error": .string(String(describing: error))])
        return true
      },
      body
    )
  }

  /// The token exchange additionally retries 401/403: a freshly minted registration token needs a
  /// moment to propagate, exactly as the Go client's custom `CheckRetry` allows for.
  func runTokenExchange<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await policy.run(
      sleep: sleep, random: random,
      retryAfter: { ($0 as? GitHubControlError)?.retryAfter },
      shouldRetry: { error in
        guard let error = error as? GitHubControlError else { return false }
        switch error.errorClass {
        case .authentication, .authorization: return true
        default: return error.errorClass.retryable
        }
      },
      body
    )
  }
}

/// One GitHub scope's connection to the Actions service (spec §50).
///
/// Owns the two-step credential dance: a REST runner **registration token**, exchanged at
/// `POST /actions/runner-registration` for the tenant's `{url, token}`. The token is a JWT whose
/// `exp` drives the refresh, so a long-lived daemon never sends a dead token. Neither token is ever
/// logged or persisted.
actor ActionsServiceConnection {
  private struct Admin: Sendable {
    var serviceURL: URL
    var token: String
    var expiresAt: Date
  }

  private let scope: GitHubScope
  private let http: GitHubHTTPClient
  private let apiBaseURL: URL
  private let configURL: URL
  private let session: URLSession
  private let options: ActionsServiceOptions
  private let logger: Logger
  private let now: @Sendable () -> Date

  nonisolated let userAgent: String
  nonisolated let retry: ActionsRetry

  private var admin: Admin?
  private var refresh: Task<Admin, any Error>?

  init(
    scope: GitHubScope, http: GitHubHTTPClient, apiBaseURL: URL, configBaseURL: URL,
    session: URLSession, systemInfo: ActionsSystemInfo, options: ActionsServiceOptions,
    logger: Logger, retry: ActionsRetry, now: @escaping @Sendable () -> Date
  ) {
    self.scope = scope
    self.http = http
    self.apiBaseURL = apiBaseURL
    configURL = ActionsConfigURL.forScope(scope, base: configBaseURL)
    self.session = session
    self.options = options
    self.logger = logger
    self.now = now
    userAgent = systemInfo.userAgent
    self.retry = retry
  }

  // MARK: - Requests

  /// Builds an Actions-service request: tenant URL + path, `api-version`, bearer admin token.
  /// Refreshes the admin token first when it is within the margin of expiring.
  func makeRequest(
    method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
    timeout: Duration? = nil
  ) async throws -> URLRequest {
    let admin = try await adminConnection()
    var request = URLRequest(
      url: try ActionsURL.join(base: admin.serviceURL, path: path, query: query,
                               apiVersion: options.apiVersion),
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: ActionsURL.seconds(timeout ?? options.requestTimeout)
    )
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(admin.token)", forHTTPHeaderField: "Authorization")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  /// One attempt. Status classification is the caller's job: the message queue treats 202 and 401
  /// as control flow, not as failure.
  nonisolated func execute(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw ActionsErrorMapper.transportError(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw GitHubControlError.invalidResponse(reason: "\(label): response was not HTTP")
    }
    return (data, http)
  }

  func send<T: Decodable & Sendable>(
    method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
    idempotent: Bool, as type: T.Type, label: String
  ) async throws -> T {
    let data = try await sendReturningData(
      method: method, path: path, query: query, body: body, idempotent: idempotent,
      expecting: 200, label: label
    )
    return try ActionsURL.decode(T.self, from: data, label: label)
  }

  /// `DELETE` endpoints answer 204 with an empty body.
  func sendExpectingNoContent(
    method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
    idempotent: Bool, label: String
  ) async throws {
    _ = try await sendReturningData(
      method: method, path: path, query: query, body: body, idempotent: idempotent,
      expecting: 204, label: label
    )
  }

  private func sendReturningData(
    method: String, path: String, query: [URLQueryItem], body: Data?, idempotent: Bool,
    expecting: Int, label: String
  ) async throws -> Data {
    // Explicitly `@Sendable`: `ActionsRetry` is nonisolated, so the closure leaves the actor.
    let attempt: @Sendable () async throws -> Data = {
      let request = try await self.makeRequest(
        method: method, path: path, query: query, body: body
      )
      let (data, response) = try await self.execute(request, label: label)
      guard response.statusCode == expecting else {
        throw ActionsErrorMapper.error(
          status: response.statusCode, headers: response.allHeaderFields, body: data, label: label
        )
      }
      return data
    }
    return try await retry.run(idempotent: idempotent, attempt)
  }

  // MARK: - Admin token

  private func adminConnection() async throws -> Admin {
    if let admin, now() < admin.expiresAt.addingTimeInterval(-seconds(options.tokenRefreshMargin)) {
      return admin
    }
    // Concurrent callers share one exchange; the actor can be re-entered across every `await`.
    if let refresh { return try await refresh.value }
    let task = Task { try await self.exchangeCredentials() }
    refresh = task
    do {
      let fresh = try await task.value
      admin = fresh
      refresh = nil
      return fresh
    } catch {
      refresh = nil
      throw error
    }
  }

  private func exchangeCredentials() async throws -> Admin {
    logger.debug(
      "refreshing Actions service admin token", metadata: ["scope": .string(scope.description)]
    )
    let registration = try await registrationToken()
    let connection = try await adminConnection(registrationToken: registration)
    guard let rawURL = connection.url, let serviceURL = URL(string: rawURL), !rawURL.isEmpty else {
      throw GitHubControlError.invalidResponse(
        reason: "Actions service admin connection for \(scope.description) has no url"
      )
    }
    guard let token = connection.token, !token.isEmpty else {
      throw GitHubControlError.invalidResponse(
        reason: "Actions service admin connection for \(scope.description) has no token"
      )
    }
    return Admin(
      serviceURL: serviceURL, token: token,
      expiresAt: try ActionsJWT.expiry(of: token, scope: scope.description)
    )
  }

  /// `POST /{scope}/actions/runners/registration-token` over the ordinary REST client, so it picks
  /// up the configured credential, rate-limit handling and retry.
  private func registrationToken() async throws -> String {
    let path = scope.runnersPath + "/registration-token"
    let response = try await http.send(
      GitHubRequest.post(path, idempotent: true), as: ActionsWire.RegistrationToken.self
    )
    guard let token = response.value.token, !token.isEmpty else {
      throw GitHubControlError.invalidResponse(
        reason: "POST \(path): GitHub returned no registration token"
      )
    }
    return token
  }

  /// `POST {api}/actions/runner-registration`, `Authorization: RemoteAuth <registration token>`.
  /// It cannot go through `GitHubHTTPClient`: that client owns the `Authorization` header.
  private func adminConnection(registrationToken: String) async throws -> ActionsWire.AdminConnection {
    let label = "POST /actions/runner-registration"
    let body = try ActionsURL.encode(
      ["url": configURL.absoluteString, "runner_event": "register"], label: label
    )
    var request = URLRequest(
      url: try ActionsURL.join(base: apiBaseURL, path: "/actions/runner-registration", query: [],
                               apiVersion: nil),
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: ActionsURL.seconds(options.requestTimeout)
    )
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("RemoteAuth \(registrationToken)", forHTTPHeaderField: "Authorization")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let exchange = request
    let attempt: @Sendable () async throws -> ActionsWire.AdminConnection = {
      let (data, response) = try await self.execute(exchange, label: label)
      guard (200 ..< 300).contains(response.statusCode) else {
        throw ActionsErrorMapper.error(
          status: response.statusCode, headers: response.allHeaderFields, body: data, label: label
        )
      }
      return try ActionsURL.decode(ActionsWire.AdminConnection.self, from: data, label: label)
    }
    return try await retry.runTokenExchange(attempt)
  }

  private func seconds(_ duration: Duration) -> Double {
    ActionsURL.seconds(duration)
  }
}
