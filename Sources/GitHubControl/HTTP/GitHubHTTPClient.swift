import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Hardened GitHub REST transport (spec §52): explicit timeout, bounded retry with jitter,
/// `Retry-After` and rate-limit handling, cancellation, and structured error classification.
///
/// Every knob a test needs — session, clock, sleep, randomness — is injected, so the whole retry
/// machine is exercised without a socket or a wall-clock wait.
public actor GitHubHTTPClient {
  public static let defaultBaseURL = URL(string: "https://api.github.com")!

  /// Tunables that are not worth a positional argument each.
  public struct Options: Sendable, Hashable {
    /// Per-attempt deadline, applied to the `URLRequest` itself.
    public var timeout: Duration
    public var retryPolicy: RetryPolicy
    /// A `Retry-After` longer than this is surfaced to the caller instead of being slept through:
    /// a scheduler can do something useful with an hour, a blocked task cannot.
    public var maxRetryAfter: Duration
    public var userAgent: String
    public var apiVersion: String
    /// Guards against a server that keeps advertising a next page.
    public var maxPages: Int
    public var pageSize: Int

    public init(
      timeout: Duration = .seconds(30), retryPolicy: RetryPolicy = .github,
      maxRetryAfter: Duration = .seconds(120), userAgent: String = "RunnerVM",
      apiVersion: String = GitHubControlModule.apiVersion, maxPages: Int = 20, pageSize: Int = 100
    ) {
      self.timeout = timeout
      self.retryPolicy = retryPolicy
      self.maxRetryAfter = maxRetryAfter
      self.userAgent = userAgent
      self.apiVersion = apiVersion
      self.maxPages = maxPages
      self.pageSize = pageSize
    }
  }

  private let baseURL: URL
  private let credentials: any GitHubCredentialProvider
  private let session: URLSession
  private let options: Options
  private let logger: Logger
  private let sleep: @Sendable (Duration) async throws -> Void
  private let random: @Sendable (ClosedRange<Double>) -> Double
  private let now: @Sendable () -> Date
  private let observer: (any GitHubRequestObserver)?
  private let decoder = JSONDecoder()

  public init(
    baseURL: URL = GitHubHTTPClient.defaultBaseURL,
    credentials: any GitHubCredentialProvider,
    session: URLSession = .shared,
    options: Options = Options(),
    logger: Logger = Logger(component: .github),
    observer: (any GitHubRequestObserver)? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.baseURL = baseURL
    self.credentials = credentials
    self.session = session
    self.options = options
    self.logger = logger
    self.observer = observer
    self.sleep = sleep
    self.random = random
    self.now = now
  }

  // MARK: - Sending

  public func send<T: Decodable & Sendable>(
    _ request: GitHubRequest, as type: T.Type
  ) async throws -> GitHubResponse<T> {
    // Explicitly `@Sendable`: `RetryPolicy.run` is nonisolated, so the closures leave the actor.
    let attempt: @Sendable () async throws -> GitHubResponse<T> = {
      try await self.attempt(request, as: T.self)
    }
    let retryAfter: @Sendable (any Error) -> Duration? = { ($0 as? GitHubControlError)?.retryAfter }
    let shouldRetry: @Sendable (any Error) -> Bool = { [options] error in
      guard let error = error as? GitHubControlError, error.errorClass.retryable, request.idempotent
      else { return false }
      // A wait longer than the ceiling belongs to the scheduler, not to a blocked request.
      if let wait = error.retryAfter, wait > options.maxRetryAfter { return false }
      return true
    }
    return try await options.retryPolicy.run(
      sleep: sleep, random: random, retryAfter: retryAfter, shouldRetry: shouldRetry, attempt
    )
  }

  /// For endpoints whose body RunnerVM ignores (`DELETE` runner, for example).
  @discardableResult
  public func send(_ request: GitHubRequest) async throws -> GitHubResponse<NoContent> {
    try await send(request, as: NoContent.self)
  }

  /// Follows `Link: rel="next"` until GitHub stops offering one (spec §134 group lookup needs it).
  public func paginate<Page: Decodable & Sendable, Item: Sendable>(
    _ request: GitHubRequest, of pageType: Page.Type,
    items: @Sendable @escaping (Page) -> [Item]
  ) async throws -> [Item] {
    var next = withPageSize(request)
    var collected: [Item] = []
    for _ in 0 ..< options.maxPages {
      let response = try await send(next, as: Page.self)
      collected.append(contentsOf: items(response.value))
      guard let link = response.nextPage else { return collected }
      next = GitHubRequest.following(link)
    }
    logger.warning(
      "pagination stopped at the page limit",
      metadata: [
        "request": .string(request.logDescription),
        "max_pages": .stringConvertible(options.maxPages),
      ]
    )
    return collected
  }

  private func withPageSize(_ request: GitHubRequest) -> GitHubRequest {
    guard request.absoluteURL == nil, !request.query.contains(where: { $0.name == "per_page" }) else {
      return request
    }
    var sized = request
    sized.query.append(URLQueryItem(name: "per_page", value: String(options.pageSize)))
    return sized
  }

  // MARK: - One attempt

  private func attempt<T: Decodable & Sendable>(
    _ request: GitHubRequest, as type: T.Type
  ) async throws -> GitHubResponse<T> {
    let urlRequest = try await makeURLRequest(request)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch {
      await observer?.observe(request, outcome: .transport)
      throw Self.transportError(error)
    }
    guard let http = response as? HTTPURLResponse else {
      await observer?.observe(request, outcome: .transport)
      throw GitHubControlError.invalidResponse(
        reason: "\(request.logDescription): response was not HTTP"
      )
    }
    let headers = GitHubHeaders(http.allHeaderFields)
    log(request, status: http.statusCode, headers: headers)
    guard (200 ..< 300).contains(http.statusCode) else {
      let error = GitHubErrorMapper.error(
        status: http.statusCode, headers: headers, body: data, request: request, now: now()
      )
      await observer?.observe(request, outcome: Self.outcome(status: http.statusCode, error: error))
      throw error
    }
    do {
      let value = try decode(T.self, from: data, request: request)
      await observer?.observe(request, outcome: .success)
      return GitHubResponse(value: value, status: http.statusCode, headers: headers)
    } catch {
      await observer?.observe(request, outcome: .decode)
      throw error
    }
  }

  /// The mapper already distinguishes a rate limit from a plain 403/429; the class follows it.
  private static func outcome(status: Int, error: any Error) -> GitHubRequestOutcome {
    if case .rateLimited = error as? GitHubControlError { return .rateLimited }
    return status >= 500 ? .serverError : .clientError
  }

  private func makeURLRequest(_ request: GitHubRequest) async throws -> URLRequest {
    let credential = try await credentials.credential()
    var urlRequest = try URLRequest(
      url: request.url(relativeTo: baseURL),
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: Self.seconds(options.timeout)
    )
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
    urlRequest.setValue(options.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
    urlRequest.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
    urlRequest.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
    if request.body != nil {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return urlRequest
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data, request: GitHubRequest) throws -> T {
    if data.isEmpty, let empty = NoContent() as? T { return empty }
    do {
      return try decoder.decode(T.self, from: data)
    } catch let error as DecodingError {
      // The body is never included: it can carry an `encoded_jit_config`.
      throw GitHubControlError.invalidResponse(
        reason: "\(request.logDescription): could not decode \(T.self) — \(Self.summarize(error))"
      )
    }
  }

  /// A cancelled `URLSession` task surfaces as `URLError.cancelled`; the retry loop must see a
  /// `CancellationError` instead or it would keep trying.
  private static func transportError(_ error: any Error) -> any Error {
    if error is CancellationError { return error }
    if let urlError = error as? URLError {
      if urlError.code == .cancelled { return CancellationError() }
      return GitHubControlError.transport(cause: urlError)
    }
    return GitHubControlError.transport(cause: error)
  }

  /// Sub-second timeouts must survive the conversion: `URLRequest` reads 0 as "use the default
  /// 60 s", which would silently drop the deadline.
  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }

  private static func summarize(_ error: DecodingError) -> String {
    switch error {
    case let .keyNotFound(key, _): "missing key '\(key.stringValue)'"
    case let .typeMismatch(type, context): "expected \(type) at \(path(context))"
    case let .valueNotFound(type, context): "null \(type) at \(path(context))"
    case .dataCorrupted: "malformed JSON"
    @unknown default: "invalid JSON"
    }
  }

  private static func path(_ context: DecodingError.Context) -> String {
    context.codingPath.map(\.stringValue).joined(separator: ".")
  }

  private func log(_ request: GitHubRequest, status: Int, headers: GitHubHeaders) {
    var metadata: Logger.Metadata = [
      "request": .string(request.logDescription), "status": .stringConvertible(status),
    ]
    if let requestID = headers.requestID { metadata["github_request_id"] = .string(requestID) }
    if let remaining = headers.rateLimit?.remaining {
      metadata["rate_limit_remaining"] = .stringConvertible(remaining)
    }
    logger.debug("github request", metadata: metadata)
  }
}
