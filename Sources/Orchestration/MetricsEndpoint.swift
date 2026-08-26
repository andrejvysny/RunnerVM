import Foundation
import Logging
import Metrics
import Network
import RunnerCore
import RunnerLogging

/// Optional local Prometheus endpoint (spec §43): `GET /metrics` and `GET /healthz`, nothing else.
///
/// Loopback only, and enforced here rather than trusted from the configuration — metrics name
/// profiles, instances and host capacity, which is not information to put on a LAN by accident.
/// Built on `Network.framework` so RunnerVM keeps its "no third-party runtime dependency" rule.
public actor MetricsEndpoint {
  /// Bounded so a stray client cannot make the daemon buffer a request body it will never read.
  static let maxRequestBytes = 8 * 1024
  /// A scrape that has not sent a request line by then is not a scraper.
  static let idleTimeout: TimeInterval = 5

  private let host: NWEndpoint.Host
  private let requestedPort: NWEndpoint.Port
  private let render: @Sendable (String) async -> HTTPReply
  private let queue = DispatchQueue(label: "runnervm.metrics-endpoint")
  private let logger: Logger

  private var listener: NWListener?
  private var boundPort: UInt16?

  /// `listen` is `host:port` (`127.0.0.1:9095`, `[::1]:9095`). Port 0 binds an ephemeral port,
  /// which is what the tests use.
  public init(
    listen: String, snapshot: @escaping @Sendable () async -> MetricsSnapshot,
    logger: Logger = Logger(component: .metrics)
  ) throws {
    let address = try MetricsEndpoint.parse(listen)
    self.host = NWEndpoint.Host(address.host)
    self.requestedPort = address.port
    self.logger = logger
    self.render = { path in
      switch path {
      case "/metrics":
        return HTTPReply(
          status: "200 OK", contentType: PrometheusEncoder.contentType,
          body: PrometheusEncoder.encode(await snapshot()))
      case "/healthz":
        return HTTPReply(status: "200 OK", contentType: "text/plain; charset=utf-8", body: "ok\n")
      default:
        return HTTPReply(
          status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "not found\n")
      }
    }
  }

  public func start() async throws {
    guard listener == nil else { return }
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: requestedPort)
    let listener = try NWListener(using: parameters)
    let render = self.render
    listener.newConnectionHandler = { connection in
      MetricsConnection(connection, render: render).start()
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let resumed = ResumeOnce(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: resumed.succeed()
        case let .failed(error): resumed.fail(error)
        case .cancelled: resumed.fail(CancellationError())
        default: break
        }
      }
      listener.start(queue: queue)
    }
    self.listener = listener
    boundPort = listener.port?.rawValue
    logger.info(
      "metrics endpoint listening",
      metadata: ["listen": .string("\(host):\(boundPort ?? 0)")])
  }

  /// The actually bound port, which differs from the requested one when port 0 was asked for.
  public func port() -> UInt16? { boundPort }

  public func stop() {
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    boundPort = nil
  }

  // MARK: - Listen address

  struct Address {
    var host: String
    var port: NWEndpoint.Port
  }

  static func parse(_ listen: String) throws -> Address {
    let (host, portText) = try split(listen)
    guard let number = UInt16(portText), let port = NWEndpoint.Port(rawValue: number) else {
      throw reject(listen, "'\(portText)' is not a TCP port")
    }
    guard isLoopback(host) else {
      throw reject(listen, "only loopback addresses may serve metrics")
    }
    return Address(host: host, port: port)
  }

  private static func split(_ listen: String) throws -> (String, String) {
    if listen.hasPrefix("["), let close = listen.firstIndex(of: "]") {
      let host = String(listen[listen.index(after: listen.startIndex)..<close])
      let rest = listen[listen.index(after: close)...]
      guard rest.hasPrefix(":") else { throw reject(listen, "expected [host]:port") }
      return (host, String(rest.dropFirst()))
    }
    let parts = listen.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw reject(listen, "expected host:port") }
    return (String(parts[0]), String(parts[1]))
  }

  static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" || host.hasPrefix("127.")
  }

  private static func reject(_ listen: String, _ reason: String) -> ConfigurationError {
    ConfigurationError.validationFailed(issues: [
      .error(
        "METRICS_LISTEN_INVALID", "metrics.prometheus.listen",
        "\(listen): \(reason)"),
    ])
  }
}

/// One HTTP response. Small enough that a struct beats a formatter.
struct HTTPReply: Sendable {
  var status: String
  var contentType: String
  var body: String

  var bytes: Data {
    let payload = Data(body.utf8)
    let head = """
      HTTP/1.1 \(status)\r
      Content-Type: \(contentType)\r
      Content-Length: \(payload.count)\r
      Connection: close\r
      \r

      """
    return Data(head.utf8) + payload
  }
}

/// `NWConnection` is documented as safe to use from any thread — every call is funnelled onto its
/// own queue internally — but it is not annotated `Sendable`, so the box carries the guarantee.
private final class MetricsConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let render: @Sendable (String) async -> HTTPReply
  private let queue = DispatchQueue(label: "runnervm.metrics-connection")

  init(_ connection: NWConnection, render: @escaping @Sendable (String) async -> HTTPReply) {
    self.connection = connection
    self.render = render
  }

  /// The closures below capture `self` strongly on purpose: nothing else holds this object, and
  /// Network releases the handlers once the connection is cancelled, which is what frees it.
  func start() {
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + MetricsEndpoint.idleTimeout) { self.connection.cancel() }
    connection.receive(
      minimumIncompleteLength: 1, maximumLength: MetricsEndpoint.maxRequestBytes
    ) { data, _, _, error in
      guard error == nil, let data else {
        self.connection.cancel()
        return
      }
      self.answer(data)
    }
  }

  private func answer(_ data: Data) {
    let request = String(decoding: data.prefix(MetricsEndpoint.maxRequestBytes), as: UTF8.self)
    guard let line = request.split(separator: "\r\n", maxSplits: 1).first else {
      return finish(HTTPReply(status: "400 Bad Request", contentType: "text/plain", body: "bad\n"))
    }
    let fields = line.split(separator: " ")
    guard fields.count >= 2 else {
      return finish(HTTPReply(status: "400 Bad Request", contentType: "text/plain", body: "bad\n"))
    }
    guard fields[0] == "GET" else {
      return finish(
        HTTPReply(status: "405 Method Not Allowed", contentType: "text/plain", body: "no\n"))
    }
    // Query strings are ignored: neither route takes a parameter, and echoing one back would be
    // the only way user input could reach this response.
    let path = String(fields[1].split(separator: "?", maxSplits: 1)[0])
    let render = self.render
    Task { self.finish(await render(path)) }
  }

  private func finish(_ reply: HTTPReply) {
    connection.send(
      content: reply.bytes, completion: .contentProcessed { _ in self.connection.cancel() })
  }
}

/// `NWListener.stateUpdateHandler` can fire more than once; a continuation may only resume once.
private final class ResumeOnce: @unchecked Sendable {
  private let continuation: CheckedContinuation<Void, any Error>
  private let lock = NSLock()
  private var done = false

  init(_ continuation: CheckedContinuation<Void, any Error>) {
    self.continuation = continuation
  }

  func succeed() {
    guard claim() else { return }
    continuation.resume()
  }

  func fail(_ error: any Error) {
    guard claim() else { return }
    continuation.resume(throwing: error)
  }

  private func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !done else { return false }
    done = true
    return true
  }
}
