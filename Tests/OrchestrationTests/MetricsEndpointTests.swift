import Foundation
import Metrics
import RunnerCore
import Testing

@testable import Orchestration

/// The optional Prometheus endpoint (spec §43). Every case binds `127.0.0.1:0` and asks the
/// endpoint which port it got, so nothing here depends on a fixed port being free.
@Suite struct MetricsEndpointTests {
  /// Guarantees the listener is closed before the test returns, however the body ends.
  private func withEndpoint(
    _ registry: MetricRegistry = MetricRegistry(),
    _ body: (UInt16) async throws -> Void
  ) async throws {
    let endpoint = try MetricsEndpoint(
      listen: "127.0.0.1:0", snapshot: { await registry.snapshot() })
    try await endpoint.start()
    let port = try #require(await endpoint.port())
    do {
      try await body(port)
    } catch {
      await endpoint.stop()
      throw error
    }
    await endpoint.stop()
  }

  private func get(_ path: String, port: UInt16) async throws -> (Int, String, String?) {
    let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    let (data, response) = try await URLSession(configuration: configuration).data(from: url)
    let http = try #require(response as? HTTPURLResponse)
    return (
      http.statusCode, String(decoding: data, as: UTF8.self),
      http.value(forHTTPHeaderField: "Content-Type")
    )
  }

  @Test func servesTheRegistryAsPrometheusText() async throws {
    let registry = MetricRegistry()
    await registry.increment(
      RunnerVMMetrics.sessionsTotal, labels: ["profile": "linux", "result": "completed"])
    try await withEndpoint(registry) { port in
      let (status, body, contentType) = try await get("/metrics", port: port)

      #expect(status == 200)
      #expect(contentType == PrometheusEncoder.contentType)
      #expect(body.contains("# TYPE runnervm_sessions_total counter"))
      #expect(
        body.contains("runnervm_sessions_total{profile=\"linux\",result=\"completed\"} 1"))
    }
  }

  @Test func healthzAnswersOK() async throws {
    try await withEndpoint { port in
      let (status, body, _) = try await get("/healthz", port: port)

      #expect(status == 200)
      #expect(body == "ok\n")
    }
  }

  @Test func unknownPathsAre404() async throws {
    try await withEndpoint { port in
      let (status, _, _) = try await get("/nope", port: port)

      #expect(status == 404)
    }
  }

  /// Spec §43: metrics name profiles, instances and host capacity, so a non-loopback `listen` is
  /// a configuration error rather than something the daemon quietly honours.
  @Test func nonLoopbackListenAddressesAreRefused() {
    for listen in ["0.0.0.0:9095", "192.168.1.10:9095", "example.com:9095", "[::]:9095"] {
      #expect(throws: ConfigurationError.self) { _ = try MetricsEndpoint.parse(listen) }
    }
  }

  @Test func loopbackListenAddressesAreAccepted() throws {
    for listen in ["127.0.0.1:9095", "127.0.0.2:1", "localhost:9095", "[::1]:9095"] {
      #expect(throws: Never.self) { _ = try MetricsEndpoint.parse(listen) }
    }
    #expect(try MetricsEndpoint.parse("127.0.0.1:9095").port.rawValue == 9_095)
  }

  @Test func malformedListenAddressesAreRefused() {
    for listen in ["127.0.0.1", "127.0.0.1:not-a-port", "127.0.0.1:70000", ""] {
      #expect(throws: ConfigurationError.self) { _ = try MetricsEndpoint.parse(listen) }
    }
  }
}
