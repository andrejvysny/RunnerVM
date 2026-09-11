import Foundation
import Logging
import RunnerCore
import Testing

@testable import Orchestration

@Suite struct HostIdentityTests {
  @Test func identityIsStableAcrossLoads() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let first = try HostIdentity.load(stateDir: tree.paths.stateDir)
    let second = try HostIdentity.load(stateDir: tree.paths.stateDir)
    #expect(first == second)
    #expect(!first.rawValue.isEmpty)
  }

  @Test func identityIsWrittenToTheStateDirectory() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let id = try HostIdentity.load(stateDir: tree.paths.stateDir)
    let file = tree.paths.stateDir.appending(path: HostIdentity.fileName)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == id.rawValue)
  }

  @Test func distinctStateDirectoriesGetDistinctIdentities() throws {
    let a = try TempTree()
    let b = try TempTree()
    defer { a.remove(); b.remove() }
    let first = try HostIdentity.load(stateDir: a.paths.stateDir)
    let second = try HostIdentity.load(stateDir: b.paths.stateDir)
    #expect(first != second)
  }
}

@Suite struct DaemonLockTests {
  @Test func secondAcquisitionFailsWhileTheFirstIsHeld() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let path = tree.root.appending(path: "runnerd.lock")
    let held = try DaemonLock.acquire(at: path)
    defer { held.release() }

    #expect(throws: OrchestrationError.self) { _ = try DaemonLock.acquire(at: path) }
    do {
      _ = try DaemonLock.acquire(at: path)
    } catch let error as OrchestrationError {
      #expect(error.code == "DAEMON_ALREADY_RUNNING")
    }
  }

  @Test func releasingLetsAnotherProcessTakeTheLock() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let path = tree.root.appending(path: "runnerd.lock")
    let first = try DaemonLock.acquire(at: path)
    first.release()
    let second = try DaemonLock.acquire(at: path)
    second.release()
  }

  @Test func releaseIsIdempotent() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let lock = try DaemonLock.acquire(at: tree.root.appending(path: "runnerd.lock"))
    lock.release()
    lock.release()
  }
}

@Suite struct HostProbeTests {
  @Test func stubProbeIsDecodedIntoHostFacts() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let result = await HostProbe.run(
      executable: try tree.vmworkerStub(), logger: Logger(label: "test"))
    #expect(result.probeSucceeded)
    #expect(result.architecture == "arm64")
    #expect(result.facts.logicalCPUCount == 12)
    #expect(result.facts.maximumAllowedMemoryBytes == 68_719_476_736)
    #expect(result.macOSGuestLimit == 2)
  }

  @Test func missingBinaryFallsBackToProcessInfo() async throws {
    let result = await HostProbe.run(
      executable: URL(fileURLWithPath: "/tmp/rvm-not-a-binary-\(UUID().uuidString)"),
      logger: Logger(label: "test"))
    #expect(!result.probeSucceeded)
    #expect(result.failureReason != nil)
    #expect(result.facts.logicalCPUCount == ProcessInfo.processInfo.activeProcessorCount)
  }

  @Test func noExecutableAtAllStillProducesFacts() async throws {
    let result = await HostProbe.run(executable: nil, logger: Logger(label: "test"))
    #expect(!result.probeSucceeded)
    #expect(result.facts.physicalMemoryBytes > 0)
  }

  /// A wedged probe used to hang runnerd's startup forever, before the socket was ever bound.
  @Test func aProbeThatNeverExitsFallsBackAtTheDeadline() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let stub = try tree.hangingVMWorkerStub()
    let started = ContinuousClock.now
    let result = try await withHangGuard("the probe deadline to fire") {
      await HostProbe.run(
        executable: stub, logger: Logger(label: "test"), deadline: .milliseconds(300))
    }
    #expect(!result.probeSucceeded)
    #expect(result.failureReason?.contains("timed out") == true)
    // The child sleeps 30 s; anything near that means the deadline did not end the call.
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  /// Draining stdout to EOF before touching stderr deadlocks against a probe whose diagnostics
  /// fill the 64 KiB stderr buffer first.
  @Test func aProbeThatFloodsStderrFirstStillDecodes() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let stub = try tree.noisyVMWorkerStub()
    let result = try await withHangGuard("the noisy probe to be drained") {
      await HostProbe.run(
        executable: stub, logger: Logger(label: "test"), deadline: .seconds(10))
    }
    #expect(result.probeSucceeded)
    #expect(result.facts.logicalCPUCount == 12)
  }
}

/// D11. A probe that could not answer says something about that one run of `vmworker probe`, not
/// about the host, yet its verdict used to pin `virtualizationSupported: false` into
/// `system.status` for the daemon's whole life.
@Suite struct HostProbeMaintenanceTests {
  /// What a timed-out startup probe leaves behind.
  private static var degraded: HostProbeResult {
    var result = M2Harness.probe()
    result.virtualizationSupported = false
    result.probeSucceeded = false
    result.probeTimedOut = true
    result.failureReason = "vmworker probe timed out after 60.0s"
    return result
  }

  @Test func aDegradedProbeIsRerunOnTheMaintenanceTickAndCanRecover() async throws {
    try await withHarness { harness in
      let stub = try harness.tree.countingVMWorkerStub()
      let service = harness.service(probe: Self.degraded, vmworkerExecutable: stub)
      #expect(await service.probe.probeSucceeded == false)

      await service.runMaintenance()

      #expect(await service.probe.probeSucceeded)
      #expect(await service.probe.virtualizationSupported)
      #expect(await service.probe.failureReason == nil)
      #expect(harness.tree.vmworkerCallCount == 1)

      // And then left alone: the probe answers a capability question, not a liveness one.
      await service.runMaintenance()
      #expect(harness.tree.vmworkerCallCount == 1)
    }
  }

  @Test func aHealthyProbeIsNeverRerun() async throws {
    try await withHarness { harness in
      let stub = try harness.tree.countingVMWorkerStub()
      let service = harness.service(vmworkerExecutable: stub)

      await service.runMaintenance()

      #expect(harness.tree.vmworkerCallCount == 0)
    }
  }

  /// Only a *timed-out* probe is worth re-running. An unsigned or undecodable helper answers the
  /// same way every time, so re-probing it would be five minutes of identical warnings.
  @Test func aProbeDegradedForAnyOtherReasonIsNotRetried() async throws {
    try await withHarness { harness in
      let stub = try harness.tree.countingVMWorkerStub()
      var unsigned = Self.degraded
      unsigned.probeTimedOut = false
      unsigned.failureReason = "vmworker probe exited 1: code signature invalid"
      let service = harness.service(probe: unsigned, vmworkerExecutable: stub)

      await service.runMaintenance()

      #expect(harness.tree.vmworkerCallCount == 0)
      #expect(await service.probe.failureReason == unsigned.failureReason)
    }
  }

  /// A `vmworker` that is not on this host is a static fact; re-running the lookup every five
  /// minutes would be five minutes of identical warnings and nothing else.
  @Test func aMissingExecutableIsNotRetried() async throws {
    try await withHarness { harness in
      let service = harness.service(
        probe: Self.degraded,
        vmworkerExecutable: URL(fileURLWithPath: "/tmp/rvm-no-vmworker-\(UUID().uuidString)"))

      await service.runMaintenance()

      #expect(await service.probe.failureReason == Self.degraded.failureReason)
      #expect(await service.probe.probeTimedOut)
    }
  }
}

@Suite struct ReconcilerTests {
  @Test func tickAdvancesTheSnapshot() async {
    let reconciler = Reconciler(logger: Logger(label: "test"))
    #expect(await reconciler.state().lastRunAt == nil)
    await reconciler.tick()
    let state = await reconciler.state()
    #expect(state.runCount == 1)
    #expect(state.lastRunAt != nil)
    #expect(state.errorCount == 0)
  }

  @Test func failuresAreCounted() async {
    let reconciler = Reconciler(logger: Logger(label: "test"))
    await reconciler.recordFailure("boom")
    let state = await reconciler.state()
    #expect(state.errorCount == 1)
    #expect(state.lastError == "boom")
  }
}

@Suite struct ReconcileScheduleTests {
  @Test func jitterStaysInsideTheConfiguredWindow() {
    for _ in 0..<200 {
      let delay = DaemonRuntime.nextDelay(interval: .seconds(10), jitter: .seconds(2))
      #expect(delay >= .seconds(8))
      #expect(delay <= .seconds(12))
    }
  }

  @Test func zeroJitterKeepsTheIntervalExact() {
    #expect(DaemonRuntime.nextDelay(interval: .seconds(10), jitter: .zero) == .seconds(10))
  }
}
