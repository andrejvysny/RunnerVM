import Foundation
import RPC
import Testing

@testable import GuestControl

/// The payload shapes are the contract with the Go agent (`GuestAgent/internal/agent/payloads.go`).
/// Every expectation here is a literal from `Proto/guest_agent.md`, so a renamed field fails the
/// build's tests instead of a running VM.
@Suite struct GuestWireTests {
  private func json(_ value: some Encodable) throws -> String {
    try GuestCoding.payload(value).encodedString()
  }

  @Test func helloPinsTheDocumentedShape() throws {
    let hello = HelloResponse(
      agentVersion: "0.1.0", os: "linux", arch: "arm64", hostname: "rvm-linux-abc",
      bootId: "boot-1", capabilities: ["exec", "metrics"])
    #expect(try json(hello) == """
      {"agentVersion":"0.1.0","arch":"arm64","bootId":"boot-1",\
      "capabilities":["exec","metrics"],"hostname":"rvm-linux-abc","os":"linux",\
      "protocolVersion":1}
      """)
    let decoded = try GuestCoding.decode(
      HelloResponse.self,
      from: try StrictJSON.parse(Array("""
        {"protocolVersion":1,"agentVersion":"0.1.0","os":"linux","arch":"arm64",
         "hostname":"rvm-linux-abc","bootId":"boot-1","capabilities":["exec","metrics"]}
        """.utf8)))
    #expect(decoded == hello)
    #expect(decoded.has(capability: "exec"))
  }

  @Test func healthPinsTheDocumentedShape() throws {
    #expect(try json(HealthResponse(state: .ready)) == #"{"reasons":[],"state":"ready"}"#)
    #expect(
      try json(HealthResponse(state: .shuttingDown, reasons: ["stopping"]))
        == #"{"reasons":["stopping"],"state":"shuttingDown"}"#)
    #expect(GuestHealthState.allCases.map(\.rawValue)
      == ["starting", "ready", "degraded", "shuttingDown"])
  }

  @Test func infoOmitsAbsentVersions() throws {
    let info = GuestInfo(ipAddresses: ["10.0.0.2"], uptimeSec: 91, kernel: "6.8.0")
    #expect(try json(info) == #"{"ipAddresses":["10.0.0.2"],"kernel":"6.8.0","uptimeSec":91}"#)
    let full = GuestInfo(
      ipAddresses: [], uptimeSec: 1, kernel: "6.8.0", runnerVersion: "2.317.0",
      dockerVersion: "26.1.0")
    #expect(try json(full) == """
      {"dockerVersion":"26.1.0","ipAddresses":[],"kernel":"6.8.0","runnerVersion":"2.317.0",\
      "uptimeSec":1}
      """)
  }

  /// Spec §39: every count is an integer, only percentages and load averages are floating point.
  @Test func metricsPinsTheSpecShape() throws {
    let payload = try GuestCoding.payload(FakeGuestAgent.Script.defaultMetrics)
    #expect(payload["timestamp"]?.stringValue == "2026-08-25T12:00:00Z")
    #expect(payload["uptimeSec"]?.intValue == 12)
    #expect(payload["cpu"]?["logicalCount"]?.intValue == 2)
    #expect(payload["cpu"]?["usagePercent"]?.doubleValue == 7.5)
    #expect(payload["cpu"]?["load15"]?.doubleValue == 0.3)
    #expect(payload["memory"]?["totalBytes"]?.intValue == 2 << 30)
    #expect(payload["memory"]?["availableBytes"]?.intValue == (2 << 30) - (512 << 20))
    #expect(payload["disk"]?["rootAvailableBytes"]?.intValue == 36 << 30)
    #expect(payload["runner"]?["processRunning"]?.boolValue == false)
    #expect(payload["runner"]?["rssBytes"]?.intValue == 0)
    #expect(payload["warnings"] == nil)
    #expect(try GuestCoding.decode(GuestMetrics.self, from: payload)
      == FakeGuestAgent.Script.defaultMetrics)
  }

  @Test func metricsAcceptsTheAgentsOptionalWarnings() throws {
    let raw = try StrictJSON.parse(Array("""
      {"timestamp":"2026-08-25T12:00:00Z","uptimeSec":3,
       "cpu":{"logicalCount":4,"usagePercent":1,"load1":0,"load5":0,"load15":0},
       "memory":{"totalBytes":1,"usedBytes":1,"availableBytes":0},
       "disk":{"rootTotalBytes":1,"rootUsedBytes":1,"rootAvailableBytes":0},
       "runner":{"processRunning":true,"pid":9,"cpuPercent":2.5,"rssBytes":128},
       "warnings":["loadavg unreadable"]}
      """.utf8))
    let metrics = try GuestCoding.decode(GuestMetrics.self, from: raw)
    #expect(metrics.warnings == ["loadavg unreadable"])
    #expect(metrics.runner.pid == 9)
    #expect(metrics.timestampDate != nil)
  }

  @Test func resizeDiskPinsTheDocumentedShape() throws {
    #expect(
      try json(ResizeDiskResponse(grown: true, rootBytes: 42))
        == #"{"grown":true,"rootBytes":42}"#)
  }

  @Test func startRunnerCarriesJitConfigButNeverDescribesIt() throws {
    let request = StartRunnerRequest(
      sessionId: "s-1", jitConfig: "eyJzZWNyZXQiOiJ0b3AifQ==", workDir: "/home/runner",
      env: ["A": "1"], labels: ["self-hosted"])
    #expect(try json(request) == """
      {"env":{"A":"1"},"jitConfig":"eyJzZWNyZXQiOiJ0b3AifQ==","labels":["self-hosted"],\
      "sessionId":"s-1","workDir":"/home/runner"}
      """)
    // The whole point of the custom description: no reflection path prints the secret.
    #expect(!"\(request)".contains("eyJzZWNyZXQiOiJ0b3AifQ=="))
    #expect(!String(reflecting: request).contains("eyJzZWNyZXQiOiJ0b3AifQ=="))
    #expect(!String(describing: request).contains("eyJzZWNyZXQiOiJ0b3AifQ=="))
    #expect("\(request)".contains("<redacted>"))
    #expect("\(request)".contains("s-1"))
  }

  @Test func runnerLifecycleShapes() throws {
    #expect(
      try json(StartRunnerResponse(pid: 91, startedAt: "2026-08-25T12:00:00Z"))
        == #"{"pid":91,"startedAt":"2026-08-25T12:00:00Z"}"#)
    #expect(try json(RunnerStatus(state: .online, pid: 91)) == #"{"pid":91,"state":"online"}"#)
    #expect(try json(RunnerStatus(state: .unknown)) == #"{"state":"unknown"}"#)
    #expect(
      try json(RunnerStatus(state: .exited, pid: 91, exitCode: 3, exitedAt: "2026-08-25T12:01:00Z"))
        == #"{"exitCode":3,"exitedAt":"2026-08-25T12:01:00Z","pid":91,"state":"exited"}"#)
    #expect(try json(StopRunnerRequest(sessionId: "s-1", graceMs: 5_000))
      == #"{"graceMs":5000,"sessionId":"s-1"}"#)
    #expect(try json(StopRunnerResponse(stopped: true)) == #"{"stopped":true}"#)
    #expect(try json(CleanupRequest(epoch: 7)) == #"{"epoch":7}"#)
    #expect(try json(CleanupResponse(ok: true, removed: ["/tmp/x"]))
      == #"{"ok":true,"removed":["/tmp/x"]}"#)
    #expect(RunnerProcessState.allCases.map(\.rawValue)
      == ["starting", "online", "busy", "exited", "unknown"])
  }

  @Test func execShapesUseBase64Data() throws {
    #expect(try json(ExecRequest(argv: ["uname", "-a"], timeoutMs: 5_000, maxOutputBytes: 1_024))
      == #"{"argv":["uname","-a"],"maxOutputBytes":1024,"timeoutMs":5000}"#)
    #expect(try json(ExecChunk(stream: .stdout, data: Data("hi\n".utf8)))
      == #"{"data":"aGkK","stream":"stdout"}"#)
    #expect(try json(ExecResult(exitCode: 0)) == #"{"exitCode":0}"#)
    let decoded = try GuestCoding.decode(
      ExecChunk.self,
      from: try StrictJSON.parse(Array(#"{"stream":"stderr","data":"aGkK"}"#.utf8)))
    #expect(decoded == ExecChunk(stream: .stderr, data: Data("hi\n".utf8)))
    #expect(ExecEvent(chunk: decoded) == .stderr(Data("hi\n".utf8)))
  }

  @Test func catalogueMatchesTheProtocolTable() {
    let expected: [GuestMethod: MethodClass] = [
      .hello: .readOnly, .health: .readOnly, .getInfo: .readOnly, .getMetrics: .readOnly,
      .runnerStatus: .readOnly,
      .resizeDisk: .idempotentMutation, .stopRunner: .idempotentMutation,
      .cleanup: .idempotentMutation,
      .startRunner: .singleShot, .exec: .singleShot, .shutdown: .singleShot,
    ]
    #expect(GuestMethod.allCases.count == expected.count)
    for method in GuestMethod.allCases {
      #expect(method.methodClass == expected[method], "\(method.rawValue)")
    }
    #expect(GuestMethod.allCases.map(\.rawValue).sorted() == [
      "agent.cleanup", "agent.exec", "agent.getInfo", "agent.getMetrics", "agent.health",
      "agent.hello", "agent.resizeDisk", "agent.runnerStatus", "agent.shutdown",
      "agent.startRunner", "agent.stopRunner",
    ])
    #expect(GuestMethod.allCases.filter(\.isStreaming) == [.exec])
    #expect(GuestProtocolVersion.current == 1)
  }

  @Test func timestampsUseRFC3339WithZ() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let text = GuestCoding.timestamp(from: date)
    #expect(text.hasSuffix("Z"))
    #expect(!text.contains("."))
    #expect(GuestCoding.date(from: text) == date)
    // The agent may gain sub-second precision later; the host must still parse it.
    #expect(GuestCoding.date(from: "2026-08-25T12:00:00.250Z") != nil)
  }
}
