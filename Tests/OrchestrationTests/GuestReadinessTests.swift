import DaemonAPI
import Foundation
import GuestControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// `waitingForAgent -> idle` and everything downstream of it. The agent is a `FakeGuestAgent`
/// bound exactly where vmworker publishes its bridge, so the readiness path runs for real.
@Suite struct GuestReadinessTests {
  @Test func agentHandshakeMovesTheInstanceToIdle() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .waitingForAgent)
      let agent = try await harness.startGuestAgent(
        for: record.id, script: .slowStart(attempts: 2, bootId: "boot-alpha"))

      try await waitUntil("the instance to reach idle") {
        try await harness.record(record.id).state == .idle
      }
      let idle = try await harness.record(record.id)
      #expect(idle.bootId == "boot-alpha")
      #expect(idle.agentReadyAt != nil)
      #expect(idle.tainted == false)
      await agent.stop()
    }
  }

  /// The instance is kept, not swept: its directory and `failure.json` are the only evidence of
  /// why the guest never came up.
  @Test func anAgentThatNeverArrivesFailsTheInstance() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(agentReady: .milliseconds(80))
    ) { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")

      try await waitUntil("the readiness deadline to expire") {
        try await harness.record(record.id).state == .failed
      }
      let failed = try await harness.record(record.id)
      #expect(failed.failureCode == "AGENT_READY_TIMEOUT")
      #expect(failed.agentReadyAt == nil)
      let failure = try await harness.instanceStore.failureRecord(instanceId: record.id)
      #expect(failure?.phase == "waitingForAgent")
      #expect(failure?.code == "AGENT_READY_TIMEOUT")
      #expect(FileManager.default.fileExists(
        atPath: harness.paths.instanceDir(record.id).path(percentEncoded: false)))
    }
  }

  @Test func guestCallsAreRefusedBeforeTheHandshake() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      let error = await #expect(throws: GuestAgentError.self) {
        _ = try await harness.instances.metrics(id: record.id)
      }
      #expect(error?.code == "AGENT_NOT_READY")
    }
  }

  /// After a daemon restart an `idle` instance has to prove it is the boot we handed out. A new
  /// `bootId` means the guest rebooted underneath us, which voids every session assumption.
  @Test func aChangedBootIDTaintsAndInterruptsTheInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let agent = try await harness.startGuestAgent(for: record.id)
      try await waitUntil("the instance to reach idle") {
        try await harness.record(record.id).state == .idle
      }

      await agent.setBootId("boot-after-reboot")
      await harness.instances.recheckAgents()

      try await waitUntil("the instance to be interrupted") {
        try await harness.record(record.id).state == .interrupted
      }
      let interrupted = try await harness.record(record.id)
      #expect(interrupted.tainted)
      #expect(interrupted.failureCode == "AGENT_BOOT_ID_CHANGED")
      #expect(interrupted.taintReason?.contains("boot-after-reboot") == true)
      await agent.stop()
    }
  }

  @Test func anUnchangedBootIDLeavesTheInstanceIdle() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let agent = try await harness.startGuestAgent(for: record.id)
      try await waitUntil("the instance to reach idle") {
        try await harness.record(record.id).state == .idle
      }

      await harness.instances.recheckAgents()

      #expect(try await harness.record(record.id).state == .idle)
      #expect(try await harness.record(record.id).tainted == false)
      await agent.stop()
    }
  }

  @Test func stoppingCancelsTheReadinessPoll() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(agentReady: .seconds(30))
    ) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      let stopped = try await harness.instances.stop(id: record.id, force: false)

      #expect(stopped.state == .stopped)
      #expect(stopped.agentReadyAt == nil)
    }
  }
}

/// The three guest-backed daemon methods, driven through `DaemonServiceImpl` rather than the
/// manager, so the DTO mapping is exercised too.
@Suite struct GuestDaemonServiceTests {
  /// Builds a harness with an instance already past the handshake, runs `body`, then stops the
  /// fake agent and the harness -- in that order, and even if `body` throws -- before the temp
  /// tree is removed.
  private func withIdleHarness(
    script: FakeGuestAgent.Script = FakeGuestAgent.Script(),
    ssh: SSHPolicy = SSHPolicy(),
    _ body: (M2Harness, InstanceID, FakeGuestAgent) async throws -> Void
  ) async throws {
    try await withHarness(configuration: M2Harness.configuration(ssh: ssh)) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let agent = try await harness.startGuestAgent(for: record.id, script: script)
      try await waitUntil("the instance to reach idle") {
        try await harness.record(record.id).state == .idle
      }
      do {
        try await body(harness, record.id, agent)
      } catch {
        await agent.stop()
        throw error
      }
      await agent.stop()
    }
  }

  @Test func execStreamsThroughTheDaemonService() async throws {
    var script = FakeGuestAgent.Script()
    script.exec = [.stdout("one\n"), .stderr("warn\n"), .exit(5)]
    try await withIdleHarness(script: script) { harness, id, agent in
      let collector = ChunkCollector()
      let result = try await harness.service().instanceExec(
        InstanceExecRequest(id: id.rawValue, argv: ["echo", "one"], timeoutMs: 2_000)
      ) { chunk in await collector.append(chunk) }

      #expect(result.exitCode == 5)
      #expect(await collector.chunks == [
        InstanceExecChunk(stream: "stdout", data: Data("one\n".utf8)),
        InstanceExecChunk(stream: "stderr", data: Data("warn\n".utf8)),
      ])
      #expect(await agent.lastExec()?.argv == ["echo", "one"])
    }
  }

  @Test func metricsPassGuestTelemetryThroughAndAddTheWorker() async throws {
    try await withIdleHarness { harness, id, _ in
      let response = try await harness.service().instanceMetrics(
        InstanceMetricsRequest(id: id.rawValue))

      #expect(response.instanceId == id.rawValue)
      #expect(response.guest == FakeGuestAgent.Script.defaultMetrics)
      #expect(!response.collectedAt.isEmpty)
    }
  }

  @Test func sshInfoReportsTheGuestAddressAndTheProfilePolicy() async throws {
    try await withIdleHarness { harness, id, _ in
      let info = try await harness.service().instanceSSHInfo(
        InstanceSSHInfoRequest(id: id.rawValue))

      #expect(info.ipAddresses == ["192.168.64.7"])
      #expect(info.user == "runner")
      #expect(info.sshEnabled)
      #expect(info.command == "ssh runner@192.168.64.7")
    }
  }

  @Test func sshIsRefusedWhenTheProfileDisablesIt() async throws {
    try await withIdleHarness(ssh: SSHPolicy(enabled: false)) { harness, id, _ in
      let info = try await harness.service().instanceSSHInfo(
        InstanceSSHInfoRequest(id: id.rawValue))

      #expect(!info.sshEnabled)
      #expect(info.command == nil)
    }
  }

  /// `status` counts `idle` per profile; it only became reachable once the handshake landed.
  @Test func statusCountsIdleInstancesPerProfile() async throws {
    try await withIdleHarness { harness, _, _ in
      let status = try await harness.service().status()

      let linux = try #require(status.profiles.first { $0.name == "linux" })
      #expect(linux.idle == 1)
      #expect(linux.busy == 0)
      #expect(status.capacity.runningVMs == 1)
    }
  }
}

/// Collects the daemon-side exec chunks a streaming handler emits.
actor ChunkCollector {
  private(set) var chunks: [InstanceExecChunk] = []

  func append(_ chunk: InstanceExecChunk) { chunks.append(chunk) }
}
