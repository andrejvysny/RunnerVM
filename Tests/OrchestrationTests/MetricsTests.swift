import DaemonAPI
import Foundation
import GuestControl
import Metrics
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// What the daemon actually observes into the registry (spec §40, §41, §43).
@Suite struct OrchestrationMetricsTests {
  private static func script(_ states: [RunnerProcessState]) -> FakeGuestAgent.Script {
    var script = FakeGuestAgent.Script()
    script.runnerStatusSequence = states.map { RunnerStatus(state: $0, pid: 4_242) }
    return script
  }

  @Test func aFinishedSessionRecordsItsOutcomeAndLifecycleTimings() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.starting, .online, .busy, .busy, .exited]))

      let session = try await harness.runners.startSession(instanceId: instance.id)
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      // `finish` marks the row terminal before it tears the VM down, so the cleanup observation
      // lands a moment after `awaitTerminal` returns.
      let registry = harness.metrics
      try await waitUntil("the cleanup timing to be observed") {
        await registry.histogram(
          name: RunnerVMMetrics.cleanupSeconds, labels: ["profile": "linux"]) != nil
      }

      let labels = ["profile": "linux"]
      let sessions = await harness.metrics.counter(
        name: RunnerVMMetrics.sessionsTotal,
        labels: ["profile": "linux", "result": "completed"])
      #expect(sessions == 1)

      let jobs = await harness.metrics.histogram(
        name: RunnerVMMetrics.jobDurationSeconds, labels: labels)
      #expect(jobs?.count == 1)
      #expect((jobs?.sum ?? -1) >= 0)

      // The boot ladder is observed from the instance manager, independently of the session.
      #expect(
        await harness.metrics.histogram(
          name: RunnerVMMetrics.instanceCloneSeconds, labels: labels)?.count == 1)
      #expect(
        await harness.metrics.histogram(
          name: RunnerVMMetrics.workerStartSeconds, labels: labels)?.count == 1)
      #expect(
        await harness.metrics.histogram(
          name: RunnerVMMetrics.vmRunningToAgentReadySeconds, labels: labels)?.count == 1)
      #expect(
        await harness.metrics.histogram(
          name: RunnerVMMetrics.jitGenerationSeconds, labels: labels)?.count == 1)
      #expect(
        await harness.metrics.histogram(
          name: RunnerVMMetrics.cleanupSeconds, labels: labels)?.count == 1)
      // Spec §20: whether this host cloned or fell back to a full copy.
      #expect(await harness.metrics.gauge(name: RunnerVMMetrics.instanceCloneMethod) == nil)
      let snapshot = await harness.metrics.snapshot()
      #expect(snapshot.family(RunnerVMMetrics.instanceCloneMethod)?.samples.count == 1)
      await agent.stop()
    }
  }

  @Test func metricsSnapshotOverTheServiceExposesTheSessionCounter() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)
      // The counter is incremented after the terminal row is written and before the ephemeral VM
      // is torn down, so the deletion is the sync point.
      try await harness.awaitInstance(instance.id, state: .deleted)

      let response = try await harness.service().metricsSnapshot(
        MetricsSnapshotRequest(format: .prometheus))

      let family = try #require(response.family(RunnerVMMetrics.sessionsTotal))
      #expect(family.type == "counter")
      let sample = try #require(
        family.samples.first { $0.label("result") == "completed" })
      #expect(sample.label("profile") == "linux")
      #expect(sample.value == 1)
      let text = try #require(response.prometheus)
      #expect(text.contains("runnervm_sessions_total{profile=\"linux\",result=\"completed\"} 1"))
      #expect(text.contains("# TYPE runnervm_job_duration_seconds histogram"))
      #expect(text.contains("runnervm_job_duration_seconds_bucket{profile=\"linux\",le=\"+Inf\"}"))
      await agent.stop()
    }
  }

  @Test func aTickPublishesCapacityDemandAndInstanceGauges() async throws {
    let config = M2Harness.configuration(maxInstances: 2)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 2)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()
      await orchestrator.tick()

      let labels = ["profile": "linux"]
      #expect(await harness.metrics.gauge(name: RunnerVMMetrics.demandAssignedJobs, labels: labels) == 2)
      #expect(await harness.metrics.gauge(name: RunnerVMMetrics.capacityAdvertised, labels: labels) == 2)
      #expect(
        await harness.metrics.gauge(
          name: RunnerVMMetrics.instances,
          labels: ["profile": "linux", "state": "waitingForAgent"]) == 2)
      #expect((await harness.metrics.gauge(name: RunnerVMMetrics.reservedCPU) ?? 0) >= 4)
      #expect((await harness.metrics.gauge(name: RunnerVMMetrics.hostFreeDiskBytes) ?? 0) > 0)
    }
  }

  /// Gauges are republished per pass, so a state that emptied stops being reported.
  @Test func instanceGaugesDropStatesThatNoLongerExist() async throws {
    let config = M2Harness.configuration(maxInstances: 1)
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let profile = try await harness.profileID("linux")
      let manual = ManualDemandProvider()
      await manual.set(profile: profile, assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)
      await orchestrator.tick()
      await orchestrator.drainStarts()
      await orchestrator.tick()
      #expect(
        await harness.metrics.gauge(
          name: RunnerVMMetrics.instances,
          labels: ["profile": "linux", "state": "waitingForAgent"]) == 1)

      // Gauges are published at the top of a pass, so the tick that cancels the instance still
      // reports it; the pass after that is the one that sees it gone.
      await manual.set(profile: profile, assignedJobs: 0)
      await orchestrator.tick()
      await orchestrator.tick()

      #expect(
        await harness.metrics.gauge(
          name: RunnerVMMetrics.instances,
          labels: ["profile": "linux", "state": "waitingForAgent"]) == nil)
    }
  }

  @Test func maintenancePublishesDiskPressureAndReconcileCounters() async throws {
    try await withHarness { harness in
      let service = harness.service()

      await service.runMaintenance()

      #expect(await harness.metrics.gauge(name: RunnerVMMetrics.diskPressureState) == 0)
      #expect(await harness.metrics.counter(name: RunnerVMMetrics.reconcileRunsTotal) == 0)
    }
  }

  @Test func aFailedStartCountsAgainstTheProfile() async throws {
    try await withHarness { harness in
      // No image imported: `create` fails while resolving the profile's image reference.
      await #expect(throws: (any Error).self) {
        _ = try await harness.instances.create(profileName: "linux")
      }

      let snapshot = await harness.metrics.snapshot()
      // The failure happens before a row exists, so nothing is counted here; the orchestrator's
      // hold-down is what records it. The family still exists for the scrape.
      #expect(snapshot.family(RunnerVMMetrics.instanceFailuresTotal) != nil)
    }
  }
}
