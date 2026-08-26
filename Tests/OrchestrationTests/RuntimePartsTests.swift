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
