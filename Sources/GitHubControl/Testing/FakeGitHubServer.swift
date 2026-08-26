import Foundation
import Synchronization

/// Scriptable stand-in for api.github.com.
///
/// Test support shipped in the product module (the same reason `FakeGuestAgent` is): the daemon
/// tests in other targets need it, and SwiftPM test targets cannot import each other. Nothing in
/// the daemon may construct one.
///
/// It is a `URLProtocol`, not a socket server: no port, no listen backlog, no flakiness, and the
/// real `URLSession` code path — headers, redirects, body streaming — is still exercised.
public final class FakeGitHubServer: Sendable {
  /// A request as it reached the fake, including headers, so auth can be asserted.
  public struct Recorded: Sendable, Hashable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data?

    public func header(_ name: String) -> String? {
      headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var bodyText: String? {
      body.flatMap { String(data: $0, encoding: .utf8) }
    }

    public func bodyValue(_ key: String) -> Any? {
      guard let body,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      else { return nil }
      return object[key]
    }
  }

  /// One scripted answer. `failure` models a transport error (no HTTP exchange at all).
  public struct Reply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var failure: URLError?

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
      self.status = status
      self.headers = headers
      self.body = body
      failure = nil
    }

    public static func json(
      _ raw: String, status: Int = 200, headers: [String: String] = [:]
    ) -> Reply {
      var reply = Reply(status: status, headers: headers, body: Data(raw.utf8))
      reply.headers["Content-Type"] = "application/json"
      return reply
    }

    /// GitHub's error envelope, so the classifier sees a realistic body.
    public static func error(
      _ status: Int, message: String = "problem", headers: [String: String] = [:]
    ) -> Reply {
      json("{\"message\":\"\(message)\"}", status: status, headers: headers)
    }

    public static func empty(_ status: Int = 204, headers: [String: String] = [:]) -> Reply {
      Reply(status: status, headers: headers)
    }

    public static func failure(_ code: URLError.Code) -> Reply {
      var reply = Reply(status: 0)
      reply.failure = URLError(code)
      return reply
    }
  }

  private struct State {
    var routes: [String: [Reply]] = [:]
    var recorded: [Recorded] = []
  }

  private let state = Mutex(State())
  /// Unique per instance so concurrently running tests never see each other's routes, and so
  /// `canInit(with:)` can ignore every URL that is not ours.
  public let baseURL: URL
  let host: String

  public init() {
    host = "fake-\(UUID().uuidString.lowercased()).github.invalid"
    baseURL = URL(string: "https://\(host)")!
    FakeGitHubRegistry.shared.register(self)
  }

  /// Frees the registry slot. Optional — hosts are unique — but keeps long test runs tidy.
  public func shutdown() {
    FakeGitHubRegistry.shared.unregister(host)
  }

  /// A `URLSession` wired to this fake and nothing else.
  public func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeGitHubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  // MARK: - Scripting

  /// Replies are consumed in order; the last one repeats forever, so `stub(.error(500), .json(…))`
  /// reads as "fail once, then succeed".
  public func stub(_ method: GitHubRequest.Method, _ path: String, _ replies: Reply...) {
    stub(method, path, replies: replies)
  }

  public func stub(_ method: GitHubRequest.Method, _ path: String, replies: [Reply]) {
    state.withLock { $0.routes[Self.key(method.rawValue, path)] = replies }
  }

  /// The `actions/runner` release route the image-freshness check reads (spec §53). GitHub's real
  /// payload carries far more; only these two fields are decoded.
  public func stubLatestRunnerRelease(tag: String, publishedAt: Date) {
    let stamp = ISO8601DateFormatter().string(from: publishedAt)
    stub(
      .get, GitHubRunnersAPI.latestReleasePath,
      .json("{\"tag_name\":\"\(tag)\",\"published_at\":\"\(stamp)\"}"))
  }

  /// The `actions/runner` release *list* route `RunnerVersionMonitor` reads (spec §53): a single
  /// page carrying every given release, oldest scripting need only — a test that also needs
  /// pagination stubs the route directly with `stub(.get, GitHubRunnersAPI.runnerReleasesPath, …)`.
  public func stubRunnerReleases(_ releases: [(tag: String, publishedAt: Date, prerelease: Bool)]) {
    let formatter = ISO8601DateFormatter()
    let entries = releases.map { release in
      "{\"tag_name\":\"\(release.tag)\","
        + "\"published_at\":\"\(formatter.string(from: release.publishedAt))\","
        + "\"prerelease\":\(release.prerelease),\"draft\":false}"
    }
    stub(.get, GitHubRunnersAPI.runnerReleasesPath, .json("[\(entries.joined(separator: ","))]"))
  }

  public var recorded: [Recorded] {
    state.withLock { $0.recorded }
  }

  public func requests(_ method: GitHubRequest.Method, _ path: String) -> [Recorded] {
    recorded.filter { $0.method == method.rawValue && $0.path == path }
  }

  public func reset() {
    state.withLock { $0 = State() }
  }

  // MARK: - Serving

  func respond(to recorded: Recorded) -> Reply {
    state.withLock { state in
      state.recorded.append(recorded)
      let key = Self.key(recorded.method, recorded.path)
      guard var replies = state.routes[key], !replies.isEmpty else {
        return .error(
          501, message: "fake GitHub has no route for \(recorded.method) \(recorded.path)"
        )
      }
      let reply = replies.removeFirst()
      // The last scripted reply is sticky: most tests only care about the first N calls.
      state.routes[key] = replies.isEmpty ? [reply] : replies
      return reply
    }
  }

  private static func key(_ method: String, _ path: String) -> String {
    "\(method) \(path)"
  }
}

/// Maps a request's host back to the fake that owns it.
final class FakeGitHubRegistry: Sendable {
  static let shared = FakeGitHubRegistry()

  private let servers = Mutex<[String: FakeGitHubServer]>([:])

  func register(_ server: FakeGitHubServer) {
    servers.withLock { $0[server.host] = server }
  }

  func unregister(_ host: String) {
    servers.withLock { $0[host] = nil }
  }

  func server(for url: URL?) -> FakeGitHubServer? {
    guard let host = url?.host() else { return nil }
    return servers.withLock { $0[host] }
  }
}

final class FakeGitHubURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    FakeGitHubRegistry.shared.server(for: request.url) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let server = FakeGitHubRegistry.shared.server(for: url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let reply = server.respond(to: Self.record(request, url: url))
    if let failure = reply.failure {
      client?.urlProtocol(self, didFailWithError: failure)
      return
    }
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func record(_ request: URLRequest, url: URL) -> FakeGitHubServer.Recorded {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = Dictionary(
      (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { _, last in last }
    )
    return FakeGitHubServer.Recorded(
      method: request.httpMethod ?? "GET",
      path: url.path(percentEncoded: false),
      query: query,
      headers: request.allHTTPHeaderFields ?? [:],
      body: body(of: request)
    )
  }

  /// `URLSession` rewrites `httpBody` into a stream before a protocol sees the request, so both
  /// forms have to be handled or every POST looks empty.
  private static func body(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      data.append(contentsOf: buffer[0 ..< read])
    }
    return data
  }
}
