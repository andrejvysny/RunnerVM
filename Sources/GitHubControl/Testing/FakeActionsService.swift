import Foundation
import RunnerCore
import Synchronization

/// Stateful in-process stand-in for the GitHub Actions scale-set service (spec §50).
///
/// Test support shipped in the product module for the same reason `FakeGitHubServer` is: other
/// test targets need it and SwiftPM test targets cannot import each other. Nothing in the daemon
/// may construct one.
///
/// It answers on two hosts through one `URLProtocol`, because the scale-set flow spans both:
/// `restBaseURL` serves the registration-token and `runner-registration` exchange, `actionsBaseURL`
/// serves the tenant (`/_apis/…`) and the message queue. State is real — scale sets, sessions,
/// queue cursors and runners persist across requests — so cursor and redelivery semantics can be
/// asserted instead of stubbed.
public final class FakeActionsService: Sendable {
  public typealias Recorded = FakeGitHubServer.Recorded

  struct Response: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ raw: String, status: Int = 200) -> Response {
      Response(status: status, headers: ["Content-Type": "application/json"], body: Data(raw.utf8))
    }

    static func empty(_ status: Int) -> Response {
      Response(status: status, headers: [:], body: Data())
    }

    /// The Actions service's .NET exception envelope.
    static func failure(_ status: Int, _ typeName: String, _ message: String) -> Response {
      json("{\"typeName\":\"\(typeName)\",\"message\":\"\(message)\"}", status: status)
    }
  }

  struct ScaleSetRecord: Sendable {
    var id: Int64
    var name: String
    var runnerGroupID: Int64
    var labels: [String]
    var disableUpdate: Bool
  }

  struct SessionRecord: Sendable {
    var id: String
    var scaleSetID: Int64
    var owner: String
    var queueToken: String
  }

  struct MessageRecord: Sendable {
    var id: Int64
    var type: String
    var body: String
    var statistics: ScaleSetStatistics?
    var acknowledged = false
  }

  struct RunnerRecord: Sendable {
    var id: Int64
    var name: String
    var scaleSetID: Int64
  }

  /// One scripted failure, consumed by the first matching request.
  struct Failure: Sendable {
    var pathFragment: String
    var method: String?
    var status: Int
    var message: String
    var remaining: Int
  }

  struct State {
    var recorded: [Recorded] = []
    var adminTokens: Set<String> = []
    var adminTokenLifetime: TimeInterval = 600
    var registrationTokens = 0
    var runnerGroups: [Int64: String] = [1: "default"]
    var scaleSets: [Int64: ScaleSetRecord] = [:]
    var nextScaleSetID: Int64 = 1
    var sessions: [String: SessionRecord] = [:]
    var queueTokenRotations = 0
    var messages: [MessageRecord] = []
    var nextMessageID: Int64 = 1
    var runners: [Int64: RunnerRecord] = [:]
    var nextRunnerID: Int64 = 100
    var statistics = ScaleSetStatistics()
    /// `nil` means "acquire everything asked for".
    var acquirable: Set<Int64>?
    var failures: [Failure] = []
    var expireQueueTokenCount = 0
  }

  let state = Mutex(State())

  public let restBaseURL: URL
  public let actionsBaseURL: URL
  /// What a `githubConfigUrl` is built on; the client derives the same value from `restBaseURL`.
  public var configBaseURL: URL { restBaseURL }

  let restHost: String
  let actionsHost: String
  /// The tenant prefix a real Actions service URL carries.
  static let tenantPath = "/tenant/123"

  public init() {
    let id = UUID().uuidString.lowercased()
    restHost = "fake-\(id).github.invalid"
    actionsHost = "fake-\(id).actions.invalid"
    restBaseURL = URL(string: "https://\(restHost)")!
    actionsBaseURL = URL(string: "https://\(actionsHost)\(Self.tenantPath)")!
    FakeActionsRegistry.shared.register(self)
  }

  public func shutdown() {
    FakeActionsRegistry.shared.unregister(restHost)
    FakeActionsRegistry.shared.unregister(actionsHost)
  }

  /// A `URLSession` wired to this fake and nothing else.
  public func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    install(in: configuration)
    return URLSession(configuration: configuration)
  }

  public func install(in configuration: URLSessionConfiguration) {
    configuration.protocolClasses = [FakeActionsURLProtocol.self]
  }

  // MARK: - Inspection

  public var recorded: [Recorded] {
    state.withLock { $0.recorded }
  }

  /// Requests whose path contains `fragment`, in arrival order.
  public func requests(_ method: String, containing fragment: String) -> [Recorded] {
    recorded.filter { $0.method == method && $0.path.contains(fragment) }
  }

  public var registrationTokenRequests: Int {
    requests("POST", containing: "/runners/registration-token").count
  }

  public var adminExchangeRequests: Int {
    requests("POST", containing: "/actions/runner-registration").count
  }

  public var openSessionIDs: [String] {
    state.withLock { Array($0.sessions.keys) }
  }

  public var scaleSetNames: [String] {
    state.withLock { $0.scaleSets.values.map(\.name).sorted() }
  }

  public var runnerIDs: [Int64] {
    state.withLock { $0.runners.keys.sorted() }
  }

  public var unacknowledgedMessageIDs: [Int64] {
    state.withLock { $0.messages.filter { !$0.acknowledged }.map(\.id) }
  }

  // MARK: - Scripting

  /// Seeds a scale set that already exists on the service.
  @discardableResult
  public func seedScaleSet(
    name: String, runnerGroupID: Int64 = 1, labels: [String]? = nil, disableUpdate: Bool = false
  ) -> Int64 {
    state.withLock { state in
      let id = state.nextScaleSetID
      state.nextScaleSetID += 1
      state.scaleSets[id] = ScaleSetRecord(
        id: id, name: name, runnerGroupID: runnerGroupID, labels: labels ?? [name],
        disableUpdate: disableUpdate
      )
      return id
    }
  }

  public func addRunnerGroup(id: Int64, name: String) {
    state.withLock { $0.runnerGroups[id] = name }
  }

  /// Queues a `RunnerScaleSetJobMessages` message whose body is the given raw job-message JSON
  /// objects, exactly as the service would send them.
  @discardableResult
  public func enqueue(jobMessages: [String], statistics: ScaleSetStatistics? = nil) -> Int64 {
    enqueue(
      body: "[\(jobMessages.joined(separator: ","))]",
      type: ScaleSetMessage.jobMessagesType, statistics: statistics
    )
  }

  @discardableResult
  public func enqueue(body: String, type: String, statistics: ScaleSetStatistics? = nil) -> Int64 {
    state.withLock { state in
      let id = state.nextMessageID
      state.nextMessageID += 1
      if let statistics { state.statistics = statistics }
      state.messages.append(
        MessageRecord(id: id, type: type, body: body, statistics: statistics ?? state.statistics)
      )
      return id
    }
  }

  public func setStatistics(_ statistics: ScaleSetStatistics) {
    state.withLock { $0.statistics = statistics }
  }

  /// Restricts what `acquirejobs` hands out; the rest of the request is reported as lost.
  public func setAcquirable(_ ids: [Int64]?) {
    state.withLock { $0.acquirable = ids.map(Set.init) }
  }

  /// Makes the next `count` message-queue calls answer 401, so the session-refresh path runs.
  public func expireQueueToken(times count: Int = 1) {
    state.withLock { $0.expireQueueTokenCount += count }
  }

  /// Lifetime of the `exp` claim in every admin JWT the fake mints. Short values make the client
  /// refresh on the next call.
  public func setAdminTokenLifetime(_ seconds: TimeInterval) {
    state.withLock { $0.adminTokenLifetime = seconds }
  }

  /// Fails the next `times` requests whose path contains `pathFragment`.
  public func failNext(
    containing pathFragment: String, method: String? = nil, status: Int, times: Int = 1,
    message: String = "scripted failure"
  ) {
    state.withLock {
      $0.failures.append(
        Failure(
          pathFragment: pathFragment, method: method, status: status, message: message,
          remaining: times
        )
      )
    }
  }

  public func reset() {
    state.withLock { $0 = State() }
  }
}

/// Maps a request's host back to the fake that owns it. Both of a fake's hosts point at it.
final class FakeActionsRegistry: Sendable {
  static let shared = FakeActionsRegistry()

  private let services = Mutex<[String: FakeActionsService]>([:])

  func register(_ service: FakeActionsService) {
    services.withLock {
      $0[service.restHost] = service
      $0[service.actionsHost] = service
    }
  }

  func unregister(_ host: String) {
    services.withLock { $0[host] = nil }
  }

  func service(for url: URL?) -> FakeActionsService? {
    guard let host = url?.host() else { return nil }
    return services.withLock { $0[host] }
  }
}

final class FakeActionsURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    FakeActionsRegistry.shared.service(for: request.url) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let service = FakeActionsRegistry.shared.service(for: url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let reply = service.respond(to: Self.record(request, url: url), host: url.host() ?? "")
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

  private static func record(_ request: URLRequest, url: URL) -> FakeActionsService.Recorded {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = Dictionary(
      (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { _, last in last }
    )
    return FakeActionsService.Recorded(
      method: request.httpMethod ?? "GET",
      path: url.path(percentEncoded: false),
      query: query,
      headers: request.allHTTPHeaderFields ?? [:],
      body: body(of: request)
    )
  }

  /// `URLSession` turns `httpBody` into a stream before a protocol sees it, so both forms have to
  /// be handled or every POST looks empty.
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
