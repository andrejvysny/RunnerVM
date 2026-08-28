import Foundation
import GuestControl
import RPC
import RunnerCore
import Testing

@testable import DaemonAPI

/// Server and client are the real ones; only the service is a fake. These pin the wire shape of
/// the three guest-backed instance methods, `instance.exec`'s chunk protocol in particular.
@Suite struct InstanceGuestTransportTests {
  private func withDaemon(
    _ body: (DaemonClient, FakeDaemonService) async throws -> Void
  ) async throws {
    let socket = try makeSocketPath()
    defer { removeSocketDirectory(socket) }
    let service = FakeDaemonService()
    let server = DaemonServer(service: service, socketPath: socket)
    try await server.start()
    let client = try await DaemonClient.connect(socketPath: socket)
    do {
      try await body(client, service)
    } catch {
      await client.close()
      await server.stop()
      throw error
    }
    await client.close()
    await server.stop()
  }

  @Test func theGuestBackedMethodsAreImplemented() {
    #expect(DaemonMethod.instanceExec.isImplemented)
    #expect(DaemonMethod.instanceMetrics.isImplemented)
    #expect(DaemonMethod.instanceSSHInfo.isImplemented)
    #expect(DaemonMethod.instanceSelfTest.isImplemented)
    #expect(DaemonMethod.instanceExec.isStreaming)
    #expect(DaemonMethod.instanceExec.methodClass == .singleShot)
    // Relaying a guest self-test changes nothing on either side, so it is safe to retry.
    #expect(DaemonMethod.instanceSelfTest.rawValue == "instance.selfTest")
    #expect(DaemonMethod.instanceSelfTest.methodClass == .readOnly)
    #expect(!DaemonMethod.instanceSelfTest.isStreaming)
  }

  /// The daemon adds nothing and grades nothing: what the guest reported is what the caller sees.
  @Test func selfTestRelaysTheGuestResultVerbatim() async throws {
    try await withDaemon { client, service in
      #expect(try await client.instanceSelfTest(id: "vm-1") == SelfTestResult())
      #expect(await service.selfTestId() == "vm-1")

      let checks = SelfTestResult(checks: [
        SelfTestCheck(name: "keychain.create", ok: true),
        SelfTestCheck(name: "codesign.sign", ok: false, detail: "no identity"),
      ])
      await service.setSelfTestResult(checks)
      let relayed = try await client.instanceSelfTest(id: "vm-2")
      #expect(relayed == checks)
      #expect(!relayed.passed)
    }
  }

  @Test func selfTestForAnUnknownInstanceIsNotFound() async throws {
    try await withDaemon { client, _ in
      let error = await #expect(throws: DaemonClientError.self) {
        try await client.instanceSelfTest(id: "missing")
      }
      #expect(error?.code == DaemonErrorCode.notFound)
    }
  }

  @Test func metricsPassGuestTelemetryThroughUnchanged() async throws {
    try await withDaemon { client, _ in
      let response = try await client.instanceMetrics(id: "vm-1")
      #expect(response.instanceId == "vm-1")
      #expect(response.guest == FakeGuestAgent.Script.defaultMetrics)
      #expect(response.worker?.pid == 4_242)
      #expect(response.worker?.rssBytes == 1_048_576)
    }
  }

  @Test func sshInfoBuildsAConnectionString() async throws {
    try await withDaemon { client, service in
      let enabled = try await client.instanceSSHInfo(id: "vm-1")
      #expect(enabled.user == "runner")
      #expect(enabled.command == "ssh runner@192.168.64.7")

      await service.setSSHInfo(
        InstanceSSHInfo(ipAddresses: ["10.0.0.5"], user: "runner", sshEnabled: false))
      let disabled = try await client.instanceSSHInfo(id: "vm-1")
      #expect(disabled.command == nil)
    }
  }

  /// Output arrives as chunks in order, then exactly one `exited`; the transport's empty
  /// `end: true` frame is not surfaced to the caller.
  @Test func execStreamsChunksThenTheExitCode() async throws {
    try await withDaemon { client, service in
      var events: [InstanceExecEvent] = []
      for try await event in try client.instanceExec(
        InstanceExecRequest(id: "vm-1", argv: ["uname", "-a"], timeoutMs: 5_000))
      {
        events.append(event)
      }
      #expect(events == [
        .chunk(InstanceExecChunk(stream: "stdout", data: Data("hello\n".utf8))),
        .chunk(InstanceExecChunk(stream: "stderr", data: Data("warn\n".utf8))),
        .exited(3),
      ])
      let request = await service.execRequest()
      #expect(request?.argv == ["uname", "-a"])
      #expect(request?.timeoutMs == 5_000)
    }
  }

  @Test func execChunksAreBase64OnTheWire() throws {
    let chunk = InstanceExecChunk(stream: "stdout", data: Data("hi\n".utf8))
    #expect(try JSONValue(encoding: chunk).encodedString() == #"{"data":"aGkK","stream":"stdout"}"#)
    #expect(try JSONValue(encoding: InstanceExecResult(exitCode: 7)).encodedString()
      == #"{"exitCode":7}"#)
  }

  /// A handler failure has to arrive as the terminal chunk's `error`, not as a silent end of
  /// stream — otherwise the CLI would report success for a command that never ran.
  @Test func aHandlerFailureTerminatesTheStreamWithTheDaemonError() async throws {
    try await withDaemon { client, _ in
      let error = await #expect(throws: DaemonClientError.self) {
        for try await _ in try client.instanceExec(
          InstanceExecRequest(id: "missing", argv: ["true"])) {}
      }
      #expect(error?.code == DaemonErrorCode.notFound)
    }
  }
}
