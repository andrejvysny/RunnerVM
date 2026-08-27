import Foundation
import GitHubControl
import GuestControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// WP1: what a `runnerd` restart does to the sessions it was watching (spec §69).
///
/// The invariant every case below checks is the same one: after recovery, a persisted
/// non-terminal `runner_sessions` row is either being observed again or is terminal with its
/// GitHub registration dropped and its VM handed back. The JIT config is never re-delivered —
/// it was never persisted — so re-observing is the *only* way a session survives a restart.
@Suite struct RunnerSessionRecoveryTests {
  /// One answer per `agent.runnerStatus` poll, sticking on the last.
  static func script(_ states: [RunnerProcessState]) -> FakeGuestAgent.Script {
    var script = FakeGuestAgent.Script()
    script.runnerStatusSequence = states.map { RunnerStatus(state: $0, pid: 4_242) }
    return script
  }

  static func statuses(_ states: [RunnerProcessState]) -> [RunnerStatus] {
    states.map { RunnerStatus(state: $0, pid: 4_242) }
  }

  static let exited = RunnerStatus(state: .exited, pid: 4_242, exitCode: 0, exitedAt: nil)

  // MARK: - Registration window (no runner exists yet)

  /// Nothing was asked of GitHub before the daemon died, so nothing has to be undone there.
  @Test func aPlannedOrphanIsFailedWithoutTouchingGitHub() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      let orphan = try await harness.seedOrphanSession(
        instance: instance.id, profile: "linux", state: .planned)

      let recovered = await harness.restartedRunners()
      let report = await recovered.recoverSessions()

      #expect(report.terminalized == 1)
      #expect(report.reattached == 0)
      #expect(await recovered.observedSessions().isEmpty)
      let session = try await harness.session(orphan)
      #expect(session.state == .jitFailed)
      #expect(session.failureCode == "DAEMON_RESTART")
      #expect(session.result == "recovered")
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).isEmpty)
      // Nothing to diagnose after a restart: the ephemeral VM is destroyed, not kept interrupted,
      // so its capacity returns immediately.
      try await harness.awaitInstance(instance.id, state: .deleted)
      await agent.stop()
    }
  }

  /// The POST may have been processed before the reply was lost. The VM's name is the only handle
  /// on that registration, and a runner GitHub still believes in would keep receiving jobs.
  @Test func aJitRequestedOrphanDropsTheRegistrationItFindsByName() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      harness.stubRunnerNamed(instance.name)
      let orphan = try await harness.seedOrphanSession(
        instance: instance.id, profile: "linux", state: .jitRequested)

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().terminalized == 1)

      let session = try await harness.session(orphan)
      #expect(session.state == .jitFailed)
      #expect(session.failureCode == "DAEMON_RESTART")
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 1)
      let lookup = try #require(harness.github.requests(.get, M2Harness.runnersPath).last)
      #expect(lookup.query["name"] == instance.name)
      await agent.stop()
    }
  }

  @Test func aJitRequestedOrphanWithNoRegistrationIssuesNoDelete() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      let orphan = try await harness.seedOrphanSession(
        instance: instance.id, profile: "linux", state: .jitRequested)

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().terminalized == 1)

      #expect(try await harness.session(orphan).state == .jitFailed)
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).isEmpty)
      #expect(await recovered.observedSessions().isEmpty)
      await agent.stop()
    }
  }

  /// The registration exists but its config never reached the guest, and it never will: the JIT
  /// secret was not persisted, so the only safe answer is to drop the runner and take the VM down.
  @Test func aJitIssuedOrphanRemovesTheRunnerAndRetiresTheVM() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      let orphan = try await harness.seedOrphanSession(
        instance: instance.id, profile: "linux", state: .jitIssued,
        githubRunnerId: M2Harness.runnerID)

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().terminalized == 1)

      let session = try await harness.session(orphan)
      #expect(session.state == .runnerStartFailed)
      #expect(session.failureCode == "DAEMON_RESTART")
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 1)
      // Ephemeral, and failed only because the daemon restarted: destroyed, not kept for diagnosis.
      try await harness.awaitInstance(instance.id, state: .deleted)
      #expect(harness.github.requests(.post, M2Harness.jitPath).isEmpty)
      await agent.stop()
    }
  }

  // MARK: - Re-adoption (the runner may still be running)

  /// The happy restart: the guest kept running the job, so the daemon picks the session back up
  /// and lets the ordinary observer finish it.
  @Test func aRunnerThatSurvivedTheRestartIsReAdoptedAndCompletes() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))
      let session = try await harness.runners.startSession(instanceId: instance.id)

      await harness.simulateRestart()
      // The crash window: the row reached `jitDelivered` and the daemon died before moving it on.
      try await harness.forceSessionState(session.id, to: .jitDelivered)
      _ = try await harness.instanceReconciler().run(firstTick: true)
      await agent.setRunnerStatusSequence(Self.statuses([.online, .busy, .exited]))

      let recovered = await harness.restartedRunners()
      let report = await recovered.recoverSessions()

      #expect(report.reattached == 1)
      #expect(report.terminalized == 0)
      #expect(await recovered.observedSessions() == [session.id])
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "job")
      #expect(terminal.jobStartedAt != nil)
      // The summary is written after the terminal row, so it is polled for rather than read once.
      try await waitUntil("the job summary to be written") {
        try await harness.jobSummaries().count == 1
      }
      // A JIT runner GitHub retires itself: the happy path still issues no DELETE.
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).isEmpty)
      try await waitUntil("the ephemeral VM to be deleted") {
        try await harness.record(instance.id).state == .deleted
      }
      await agent.stop()
    }
  }

  /// Regression: `jitDelivered` has no edge to `runnerLost`, so a session abandoned from there
  /// used to log an illegal transition and leave the row non-terminal forever.
  @Test func aRunnerWhoseVMDiedDuringTheRestartIsLostRatherThanStuck() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))
      let session = try await harness.runners.startSession(instanceId: instance.id)

      await harness.simulateRestart()
      try await harness.forceSessionState(session.id, to: .jitDelivered)
      await harness.launcher.killWorker(instance.id)
      await agent.stop()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      #expect(try await harness.record(instance.id).state == .interrupted)

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().terminalized == 1)

      let terminal = try await harness.session(session.id)
      #expect(terminal.state == .runnerLost)
      #expect(terminal.failureCode == "VM_LOST")
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 1)
      #expect(await recovered.observedSessions().isEmpty)
    }
  }

  /// A runner that never picked up a job is `completed`, not failed: nothing went wrong, GitHub
  /// simply had no work for it.
  @Test func aRunnerOnlineOrphanThatExitsWithoutAJobCompletesAsNoJob() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .online, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the runner to report online") {
        try await harness.session(session.id).state == .runnerOnline
      }

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().reattached == 1)

      await agent.setRunnerStatus(Self.exited)
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "no-job")
      #expect(terminal.jobStartedAt == nil)
      await agent.stop()
    }
  }

  /// `sawBusy` is not in memory any more, so it has to be read back off the row: a job that was
  /// already running must still be reported as a job when the runner exits.
  @Test func aJobRunningOrphanCarriesItsJobAcrossTheRestart() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().reattached == 1)

      await agent.setRunnerStatus(Self.exited)
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "job")
      #expect(terminal.jobFinishedAt != nil)
      await agent.stop()
    }
  }

  /// The VM is up but its agent is not answering: the runner is unobservable, and an unobservable
  /// job is an interrupted one.
  @Test func aJobRunningOrphanWhoseGuestIsSilentIsInterrupted() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      await agent.stop()
      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().reattached == 1)

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .jobInterrupted)
      #expect(terminal.failureCode == "RUNNER_STATUS_UNAVAILABLE")
      try await waitUntil("the runner to be removed from GitHub") {
        !harness.github.requests(.delete, M2Harness.runnerPath).isEmpty
      }
    }
  }

  /// Restarting in the gap between the job finishing and the row being closed: the first poll
  /// already reports `exited`, and the session must close exactly once.
  @Test func aRestartRightAfterTheJobFinishedClosesTheSessionOnce() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      await agent.setRunnerStatus(Self.exited)
      let recovered = await harness.restartedRunners()
      _ = await recovered.recoverSessions()

      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "job")
      try await waitUntil("the job summary to be written") {
        try await harness.jobSummaries().count == 1
      }
      // A second sweep sees a terminal row and does nothing; one session, one summary.
      let again = await recovered.recoverSessions()
      #expect(again == RunnerSessionManager.RecoveryReport())
      #expect(try await harness.jobSummaries().count == 1)
      await agent.stop()
    }
  }

  // MARK: - Degraded inputs

  /// The VM row is gone entirely. Closing the session must still work — and must not try to hand
  /// back a VM that no longer exists.
  @Test func aSessionWhoseInstanceWasDeletedIsStillClosed() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance()
      let orphan = try await harness.seedOrphanSession(
        instance: instance.id, profile: "linux", state: .runnerStarting,
        githubRunnerId: M2Harness.runnerID)
      _ = try await harness.instances.delete(id: instance.id)

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().terminalized == 1)

      let session = try await harness.session(orphan)
      #expect(session.state == .runnerLost)
      #expect(session.failureCode == "VM_LOST")
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 1)
      #expect(try await harness.record(instance.id).state == .deleted)
      await agent.stop()
    }
  }

  /// Regression: the session row is written before the instance row, so a crash in between leaves
  /// the VM a rung short. Without walking it up, every later `advanceRunnerState` is an illegal
  /// edge and the job is silently reported as "no-job".
  @Test func anInstanceLeftBehindTheSessionIsWalkedUpTheLadder() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(script: Self.script([.starting]))
      let session = try await harness.runners.startSession(instanceId: instance.id)

      await harness.simulateRestart()
      try await harness.forceInstanceState(instance.id, to: .configuringRunner)
      _ = try await harness.instanceReconciler().run(firstTick: true)
      await agent.setRunnerStatus(RunnerStatus(state: .busy, pid: 4_242))

      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().reattached == 1)

      try await waitUntil("the VM to catch up with its session") {
        try await harness.record(instance.id).state == .busy
      }
      try await waitUntil("the job to be running") {
        try await harness.session(session.id).state == .jobRunning
      }
      await agent.setRunnerStatus(Self.exited)
      let terminal = try await harness.awaitTerminal(session.id)
      #expect(terminal.state == .completed)
      #expect(terminal.result == "job")
      await agent.stop()
    }
  }

  /// A scope that has gone degraded stops receiving *new* sessions (spec §134). It must not stop
  /// an existing one from being finished.
  @Test func aDegradedScopeStillGetsItsSessionsBack() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (instance, agent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      try await harness.setScopeHealth("degraded")
      let recovered = await harness.restartedRunners()
      #expect(await recovered.recoverSessions().reattached == 1)

      await agent.setRunnerStatus(Self.exited)
      #expect(try await harness.awaitTerminal(session.id).state == .completed)
      _ = instance
      await agent.stop()
    }
  }

  // MARK: - Idempotence and capacity

  /// The sweep runs on every reconcile tick, so repeating it has to be free: a session already
  /// being observed is skipped, and a terminal row is not a session any more.
  @Test func repeatingTheSweepDoesNoFurtherWork() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatus = RunnerStatus(state: .busy, pid: 4_242)
      let (live, liveAgent) = try await harness.idleInstance(script: script)
      let session = try await harness.runners.startSession(instanceId: live.id)
      try await waitUntil("the job to start") {
        try await harness.session(session.id).state == .jobRunning
      }
      let (stale, staleAgent) = try await harness.idleInstance()
      let orphan = try await harness.seedOrphanSession(
        instance: stale.id, profile: "linux", state: .jitIssued,
        githubRunnerId: M2Harness.runnerID)

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)
      let recovered = await harness.restartedRunners()

      let first = await recovered.recoverSessions()
      #expect(first.reattached == 1)
      #expect(first.terminalized == 1)
      let second = await recovered.recoverSessions()
      #expect(second.reattached == 0)
      #expect(second.terminalized == 0)
      #expect(second.deferred == 1)
      #expect(await recovered.recoverSessions() == second)

      #expect(await recovered.observedSessions() == [session.id])
      #expect(harness.github.requests(.delete, M2Harness.runnerPath).count == 1)
      #expect(try await harness.session(orphan).state == .runnerStartFailed)
      await staleAgent.stop()
      await liveAgent.stop()
    }
  }

  /// The point of terminalizing at all: `OrchestratorTick` counts every non-terminal session row
  /// as an active one, so a session nobody is watching makes the profile look fully occupied and
  /// the host under-provisions until the row is closed.
  @Test func aTerminalizedOrphanLetsTheOrchestratorScheduleAgain() async throws {
    let config = M2Harness.configuration()
    try await withHarness(configuration: config) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (stale, staleAgent) = try await harness.idleInstance()
      try await harness.seedOrphanSession(
        instance: stale.id, profile: "linux", state: .jitIssued,
        githubRunnerId: M2Harness.runnerID)

      #expect(await harness.runners.recoverSessions().terminalized == 1)

      // What `InstanceReconciler.sweepRetired` does once the diagnostics window closes: until the
      // directory goes, a retired VM still holds its share of the host budget. Recovery now
      // destroys the VM itself; this only waits for that to land.
      try await harness.awaitInstance(stale.id, state: .deleted)
      await staleAgent.stop()
      let (fresh, freshAgent) = try await harness.idleInstance(
        script: Self.script([.online, .busy, .exited]))
      let manual = ManualDemandProvider()
      await manual.set(profile: try await harness.profileID("linux"), assignedJobs: 1)
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)

      await orchestrator.tick()
      await orchestrator.drainStarts()

      let started = try #require(
        try await harness.runners.list().first { $0.instanceId == fresh.id })
      #expect(try await harness.awaitTerminal(started.id).state == .completed)
      await freshAgent.stop()
    }
  }
}
