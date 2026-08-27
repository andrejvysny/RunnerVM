import Foundation
import RPC
import RunnerCore
import Testing

@testable import GuestControl

/// Round trips against a real `RPCServer` on the `guest` protocol: framing, envelopes, streaming
/// and error mapping are all exercised, only the guest OS is faked.
@Suite struct GuestAgentClientTests {
  /// Tiny backoff: readiness is driven by the fake's health script, never by wall-clock waiting.
  private static let fastPolling = GuestAgentClient.ReadinessPolicy(
    initialBackoff: .milliseconds(1), maxBackoff: .milliseconds(4))

  private func withAgent(
    script: FakeGuestAgent.Script = FakeGuestAgent.Script(),
    _ body: (GuestAgentClient, FakeGuestAgent) async throws -> Void
  ) async throws {
    let tree = try SocketTree()
    defer { tree.remove() }
    let agent = FakeGuestAgent(socketPath: tree.socket(), script: script)
    try await agent.start()
    let client = GuestAgentClient(socketPath: tree.socket())
    do {
      try await body(client, agent)
    } catch {
      await client.close()
      await agent.stop()
      throw error
    }
    await client.close()
    await agent.stop()
  }

  @Test func helloAndHealthRoundTrip() async throws {
    try await withAgent { client, agent in
      let hello = try await client.hello()
      #expect(hello == FakeGuestAgent.Script.defaultHello)
      #expect(hello.protocolVersion == GuestProtocolVersion.current)
      #expect(try await client.health() == HealthResponse(state: .ready))
      #expect(await agent.callCount(.hello) == 1)
    }
  }

  @Test func aGuestOnAnotherProtocolVersionIsRejected() async throws {
    var script = FakeGuestAgent.Script()
    script.hello.protocolVersion = 2
    try await withAgent(script: script) { client, _ in
      let error = await #expect(throws: GuestAgentError.self) { try await client.hello() }
      #expect(error?.code == "AGENT_PROTOCOL_VERSION_UNSUPPORTED")
      #expect(error?.retryable == false)
    }
  }

  @Test func infoMetricsAndResizeRoundTrip() async throws {
    try await withAgent { client, _ in
      let info = try await client.getInfo()
      let metrics = try await client.getMetrics()
      let resized = try await client.resizeDisk()
      #expect(info == FakeGuestAgent.Script.defaultInfo)
      #expect(metrics == FakeGuestAgent.Script.defaultMetrics)
      #expect(resized == ResizeDiskResponse(grown: true, rootBytes: 42 << 30))
    }
  }

  @Test func runnerLifecycleRoundTrips() async throws {
    try await withAgent { client, agent in
      let started = try await client.startRunner(
        StartRunnerRequest(sessionId: "s-1", jitConfig: "SECRET", workDir: "/home/runner"))
      #expect(started.pid == 4_242)
      #expect(started.startedAtDate != nil)
      #expect(await agent.lastRunnerSession() == "s-1")
      #expect(await agent.runningSessions() == ["s-1"])

      #expect(try await client.runnerStatus(sessionId: "s-1").state == .online)
      #expect(try await client.runnerStatus(sessionId: "nope").state == .unknown)

      let duplicate = await #expect(throws: GuestAgentError.self) {
        _ = try await client.startRunner(
          StartRunnerRequest(sessionId: "s-1", jitConfig: "SECRET"))
      }
      #expect(duplicate?.message.contains(GuestErrorCode.alreadyStarted) == true)

      #expect(try await client.stopRunner(StopRunnerRequest(sessionId: "s-1", graceMs: 100)).stopped)
      #expect(try await client.runnerStatus(sessionId: "s-1").state == .exited)
    }
  }

  @Test func cleanupIsIdempotentPerEpoch() async throws {
    var script = FakeGuestAgent.Script()
    script.cleanup = CleanupResponse(ok: true, removed: ["/home/runner/_work"])
    try await withAgent(script: script) { client, agent in
      let first = try await client.cleanup(epoch: 3)
      let replay = try await client.cleanup(epoch: 3)
      #expect(first.removed == ["/home/runner/_work"])
      #expect(replay.removed.isEmpty)
      #expect(await agent.cleanupEpochs() == [3])
    }
  }

  @Test func shutdownIsAnswered() async throws {
    try await withAgent { client, agent in
      try await client.shutdown()
      #expect(await agent.callCount(.shutdown) == 1)
    }
  }

  // MARK: - exec

  @Test func execStreamsInOrderAndEndsWithTheExitCode() async throws {
    var script = FakeGuestAgent.Script()
    script.exec = [.stdout("one\n"), .stderr("warn\n"), .stdout("two\n"), .exit(7)]
    try await withAgent(script: script) { client, agent in
      var events: [ExecEvent] = []
      for try await event in try await client.exec(
        ExecRequest(argv: ["echo", "hi"], cwd: "/tmp", timeoutMs: 1_000, maxOutputBytes: 4_096))
      {
        events.append(event)
      }
      #expect(events == [
        .stdout(Data("one\n".utf8)), .stderr(Data("warn\n".utf8)), .stdout(Data("two\n".utf8)),
        .exited(7),
      ])
      let request = await agent.lastExec()
      #expect(request?.argv == ["echo", "hi"])
      #expect(request?.cwd == "/tmp")
      #expect(request?.maxOutputBytes == 4_096)
    }
  }

  @Test func execSurfacesAGuestSideFailure() async throws {
    var script = FakeGuestAgent.Script()
    script.failures[.exec] = RPCErrorPayload(code: .invalidParams, message: "argv is empty")
    try await withAgent(script: script) { client, _ in
      let error = await #expect(throws: GuestAgentError.self) {
        for try await _ in try await client.exec(ExecRequest(argv: [])) {}
      }
      #expect(error?.code == "AGENT_METHOD_FAILED")
      #expect(error?.message.contains("argv is empty") == true)
    }
  }

  // MARK: - readiness

  @Test func waitUntilReadyPollsFromStartingToReady() async throws {
    try await withAgent(script: .slowStart(attempts: 3, bootId: "boot-xyz")) { client, agent in
      // Generous timeout on purpose: the assertion is the *number* of health polls, not wall
      // clock. A loaded CI runner can spend seconds just scheduling the four round trips.
      let hello = try await client.waitUntilReady(
        timeout: .seconds(60), policy: Self.fastPolling)
      #expect(hello.bootId == "boot-xyz")
      #expect(await agent.callCount(.health) == 4)
    }
  }

  @Test func waitUntilReadyTimesOutWithTheLastHealthReason() async throws {
    try await withAgent(script: .neverReady(reason: "docker is not running")) { client, _ in
      let error = await #expect(throws: GuestAgentError.self) {
        try await client.waitUntilReady(timeout: .milliseconds(30), policy: Self.fastPolling)
      }
      #expect(error?.code == "AGENT_READY_TIMEOUT")
      #expect(error?.message.contains("docker is not running") == true)
      #expect(error?.retryable == false)
    }
  }

  @Test func waitUntilReadyStopsOnANonRetryableFailure() async throws {
    var script = FakeGuestAgent.Script()
    script.hello.protocolVersion = 99
    try await withAgent(script: script) { client, _ in
      let error = await #expect(throws: GuestAgentError.self) {
        try await client.waitUntilReady(timeout: .seconds(30), policy: Self.fastPolling)
      }
      #expect(error?.code == "AGENT_PROTOCOL_VERSION_UNSUPPORTED")
    }
  }

  /// `waitUntilReachable` is satisfied by `agent.hello` alone, so it must return long before
  /// health ever reports `ready` -- and must never even call `agent.health`. `waitUntilReady`
  /// against that same script still has to keep polling.
  @Test func waitUntilReachableIgnoresHealthButWaitUntilReadyStillRequiresIt() async throws {
    var script = FakeGuestAgent.Script()
    script.health = Array(
      repeating: HealthResponse(state: .degraded, reasons: ["docker restarting"]), count: 2
    ) + [HealthResponse(state: .ready)]
    try await withAgent(script: script) { client, agent in
      let hello = try await client.waitUntilReachable(timeout: .seconds(30), policy: Self.fastPolling)
      #expect(hello == FakeGuestAgent.Script.defaultHello)
      #expect(await agent.callCount(.health) == 0)

      let ready = try await client.waitUntilReady(timeout: .seconds(30), policy: Self.fastPolling)
      #expect(ready == hello)
      #expect(await agent.callCount(.health) == 3)
    }
  }

  @Test func waitUntilReadyHonoursCancellation() async throws {
    let tree = try SocketTree()
    defer { tree.remove() }
    let agent = FakeGuestAgent(socketPath: tree.socket(), script: .neverReady())
    try await agent.start()
    let client = GuestAgentClient(socketPath: tree.socket())
    let task = Task {
      try await client.waitUntilReady(timeout: .seconds(60), policy: Self.fastPolling)
    }
    // One completed poll proves the loop is running before cancellation lands.
    try await waitUntil("the first health poll") { await agent.callCount(.health) >= 1 }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    await client.close()
    await agent.stop()
  }

  // MARK: - bridge behaviour

  @Test func aMissingBridgeReadsAsNotReady() async throws {
    let tree = try SocketTree()
    defer { tree.remove() }
    let client = GuestAgentClient(socketPath: tree.socket("absent.sock"))
    let error = await #expect(throws: GuestAgentError.self) { try await client.hello() }
    #expect(error?.code == "AGENT_NOT_READY")
    #expect(error?.retryable == true)
    await client.close()
  }

  /// vmworker's bridge accepts and hangs up while the guest has no agent on vsock 4050 yet. The
  /// client must read that as "not ready" and keep redialling until the deadline.
  @Test func aBridgeThatHangsUpIsRetriedUntilTheDeadline() async throws {
    let tree = try SocketTree()
    defer { tree.remove() }
    let bridge = try AcceptAndCloseServer(path: tree.socket())
    defer { bridge.stop() }
    let client = GuestAgentClient(socketPath: tree.socket())

    let direct = await #expect(throws: GuestAgentError.self) { try await client.hello() }
    #expect(direct?.code == "AGENT_TRANSPORT_CLOSED")
    #expect(direct?.retryable == true)

    let error = await #expect(throws: GuestAgentError.self) {
      try await client.waitUntilReady(timeout: .milliseconds(60), policy: Self.fastPolling)
    }
    #expect(error?.code == "AGENT_READY_TIMEOUT")
    #expect(bridge.acceptedConnections > 1)
    await client.close()
  }

  @Test func aClosedClientNeverRedials() async throws {
    let tree = try SocketTree()
    defer { tree.remove() }
    let agent = FakeGuestAgent(socketPath: tree.socket())
    try await agent.start()
    let client = GuestAgentClient(socketPath: tree.socket())
    _ = try await client.hello()
    await client.close()

    let error = await #expect(throws: GuestAgentError.self) { try await client.hello() }
    #expect(error?.code == "AGENT_TRANSPORT_CLOSED")
    await agent.stop()
  }
}

/// Bounded poll for an observable condition; fails with a message instead of flaking.
func waitUntil(
  _ description: String, attempts: Int = 400, interval: Duration = .milliseconds(5),
  _ condition: @Sendable () async throws -> Bool
) async throws {
  for _ in 0..<attempts {
    if try await condition() { return }
    try await Task.sleep(for: interval)
  }
  Issue.record("timed out waiting for \(description)")
}
