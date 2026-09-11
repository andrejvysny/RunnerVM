import Foundation
import ImageStore
import Metrics
import Persistence
import RunnerCore
import Testing
import WorkerProtocol

@testable import Orchestration

@Suite struct InstanceManagerTests {
  @Test func createBootsToWaitingForAgent() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")

      #expect(record.state == .waitingForAgent)
      #expect(record.workerGeneration == 1)
      #expect(record.workerPid != nil)
      #expect(record.name.hasPrefix("rvm-linux-"))
      #expect(record.macAddress?.hasPrefix("02:") == true)
      #expect(await harness.supervisor.state(id: record.id) == .running)

      let spec = harness.paths.instanceDir(record.id).appending(path: "spec.json")
      #expect(FileManager.default.fileExists(atPath: spec.path(percentEncoded: false)))
      #expect(try await harness.imageRows.pinCount(digest: record.imageDigest) == 1)
    }
  }

  @Test func specDigestMatchesWhatTheWorkerReports() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")
      let spec = harness.paths.instanceDir(record.id).appending(path: "spec.json")
      #expect(record.specDigest == (try WorkerSupervisor.specDigest(at: spec)))

      let decoded = try JSONDecoder().decode(
        InstanceSpecFile.self, from: try Data(contentsOf: spec))
      #expect(decoded.id == record.id)
      #expect(decoded.diskBytes == record.diskBytes)
    }
  }

  @Test func fencingMismatchFailsTheInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.nonceOverride = "deadbeefdeadbeefdeadbeefdeadbeef"
      await harness.launcher.set(behaviour)

      await #expect(throws: WorkerSupervisorError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }

      let records = try await harness.instances.list()
      let record = try #require(records.first)
      #expect(record.state == .failed)
      #expect(record.failureCode == "VM_WORKER_FENCED")
      let failure = try await harness.instanceStore.failureRecord(instanceId: record.id)
      #expect(failure?.phase == "startingWorker")
    }
  }

  @Test func workerDisconnectInterruptsTheInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      await harness.launcher.killWorker(record.id)

      try await waitUntil("the instance to be interrupted") {
        try await harness.record(record.id).state == .interrupted
      }
      let interrupted = try await harness.record(record.id)
      #expect(interrupted.failureCode == "VM_WORKER_UNRESPONSIVE")
    }
  }

  @Test func unexpectedGuestStopInterruptsTheInstance() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      await harness.launcher.worker(for: record.id)?.emit(.stopped)

      try await waitUntil("the instance to be interrupted") {
        try await harness.record(record.id).state == .interrupted
      }
      #expect(try await harness.record(record.id).failureCode == "VM_STOPPED_UNEXPECTEDLY")
    }
  }

  @Test func stopThenDeleteRemovesTheDirectoryAndUnpins() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let directory = harness.paths.instanceDir(record.id)

      let stopped = try await harness.instances.stop(id: record.id, force: false)
      #expect(stopped.state == .stopped)
      #expect(stopped.workerPid == nil)
      // `worker.shutdown{stop}` makes the worker exit, so its lock is already gone.
      #expect(await harness.supervisor.liveness(id: record.id) == .dead)

      let deleted = try await harness.instances.delete(id: record.id)
      #expect(deleted.state == .deleted)
      #expect(deleted.deletedAt != nil)
      #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
      #expect(try await harness.imageRows.pinCount(digest: image.record.digest) == 0)
    }
  }

  /// Spec §46: the SIGTERM-to-SIGKILL window is the profile's, not a hardcoded 30 s. It reaches
  /// the worker in the `worker.shutdown` payload, which is what the fake records.
  @Test func stopAndDeleteSendTheProfilesGracefulShutdownWindow() async throws {
    let config = M2Harness.configuration(gracefulShutdown: .seconds(90))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))

      _ = try await harness.instances.stop(id: record.id, force: false)

      #expect(await worker.shutdownPayloads.map(\.gracefulTimeoutMs) == [90_000])
      #expect(await worker.lastShutdownRequest?.reason == .stop)
    }
  }

  /// The window also has to reach the worker at spawn, for the shutdowns it decides on its own
  /// (hard deadline, orphan idle, SIGTERM) where no request carries one.
  @Test func theWorkerIsLaunchedWithTheProfilesGracefulShutdownWindow() async throws {
    let request = WorkerLaunchRequest(
      instanceId: InstanceID.generate(), specPath: URL(fileURLWithPath: "/tmp/spec.json"),
      socketDir: URL(fileURLWithPath: "/tmp"), generation: 3, nonce: "n",
      logPath: URL(fileURLWithPath: "/tmp/worker.log"), gracefulShutdownMs: 90_000)
    let arguments = request.arguments
    let index = try #require(arguments.firstIndex(of: "--graceful-ms"))
    #expect(arguments[index + 1] == "90000")
  }

  /// The exit wait has to outlast the grace the worker was given -- runnerd giving up first wedges
  /// the row in `deleting` -- but it is capped, so an operator's implausible window cannot park a
  /// teardown for hours.
  @Test func theWorkerExitWaitScalesWithTheGraceAndIsCapped() {
    let poll = Duration.milliseconds(200)
    // Below the floor: the configured minimum still wins.
    #expect(InstanceManager.workerExitAttempts(graceMs: 1_000, interval: poll, floor: 200) == 200)
    // 30 s grace + 15 s of forced teardown, at 200 ms a poll.
    #expect(InstanceManager.workerExitAttempts(graceMs: 30_000, interval: poll, floor: 200) == 225)
    // 10 min grace would be 3_075 polls; the ceiling is 120 s of polling.
    #expect(InstanceManager.workerExitAttempts(graceMs: 600_000, interval: poll, floor: 200) == 600)
  }

  /// `waitingForAgent` has no edge to `deleting`, so delete has to stop the VM first.
  @Test func deleteStopsARunningInstanceFirst() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      let deleted = try await harness.instances.delete(id: record.id)

      #expect(deleted.state == .deleted)
      #expect(deleted.stoppedAt != nil)
    }
  }

  /// A teardown that lost the race with a slow guest leaves the row in `deleting`, whose only
  /// legal exit is `deleted`. Retrying `delete` has to finish the job rather than refuse it.
  @Test func deleteIsResumableFromDeleting() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      _ = try await harness.instanceRows.transition(
        id: record.id, from: .waitingForAgent, to: .stopping, expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: record.id, from: .stopping, to: .deleting, expectedGeneration: nil) { _ in }

      let deleted = try await harness.instances.delete(id: record.id)

      #expect(deleted.state == .deleted)
      #expect(!FileManager.default.fileExists(
        atPath: harness.paths.instanceDir(record.id).path(percentEncoded: false)))
    }
  }

  // MARK: - Boot deadline (`timeouts.vmBoot`)

  /// The guest's own boot is minutes of work and `instance.create` does not wait for it: the RPC
  /// answers as soon as `vm.start` is acknowledged, with the row still in `startingVM`. A worker
  /// that answers `vm.start` and never reports `running` is exactly that VM, forever.
  @Test func createReturnsWhileTheVMIsStillBooting() async throws {
    // The production `vmBoot` (3m): this test is about the RPC not waiting for the boot, and the
    // budget must not expire under it.
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let manager = harness.instances

      // The guard is not a race margin: `create` returns in milliseconds, or it is waiting for a
      // boot that never comes -- which is what this bounds.
      let record = try await withHangGuard("instance.create to return") {
        try await manager.create(profileName: "linux")
      }

      #expect(record.state == .startingVM)
      #expect(record.workerPid != nil)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) == nil)
    }
  }

  /// Spec §46: `timeouts.vmBoot` bounds the whole clone-to-running window, and the half of it that
  /// outlives the create RPC is bounded by a watcher instead. The VM is failed, not deleted -- its
  /// directory and `failure.json` are the only evidence of a guest that never came up -- but the
  /// worker holding the lock, the bridge and the guest is taken down.
  @Test func aVMThatNeverReportsRunningFailsWithVMBootTimeout() async throws {
    // Two orders of magnitude above the create ladder, which takes tens of milliseconds here: the
    // budget starts at `cloning`, and under a saturated cooperative pool (`--parallel`) a ladder
    // that overran would report the timeout against `cloning` instead of the boot.
    let config = M2Harness.configuration(vmBoot: .seconds(3))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)

      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))

      let failed = try await harness.awaitInstance(record.id, state: .failed)

      #expect(failed.failureCode == "VM_BOOT_TIMEOUT")
      // `failure.json`, the worker's shutdown and the metric are all written after the transition
      // this wait observes, so they are waited for rather than read straight out from under it.
      try await waitUntil("the failure record to name the phase that overran") {
        try await harness.instanceStore.failureRecord(instanceId: record.id)?.phase == "startingVM"
      }
      let failure = try #require(try await harness.instanceStore.failureRecord(instanceId: record.id))
      #expect(failure.code == "VM_BOOT_TIMEOUT")
      #expect(failure.retryable)
      try await waitUntil("the worker to be asked to shut down") {
        await worker.shutdownRequests == 1
      }
      let directory = harness.paths.instanceDir(record.id)
      #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }
  }

  /// The other half of that deadline: a `running` event landing microseconds before it wins the
  /// row outright. The watcher re-reads and commits with a compare-and-swap, so a timeout it was
  /// already committed to reporting leaves nothing behind -- no `failure.json`, no failure metric,
  /// and no shutdown of a worker whose guest is up.
  @Test func aBootThatLandsJustBeforeTheDeadlineLeavesNoFailureBehind() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .waitingForAgent)
      let worker = try #require(await harness.launcher.worker(for: record.id))

      // Exactly what the watcher does when its deadline passes, run once the boot has landed.
      let failed = await harness.instances.failBootTimeout(
        record.id, expecting: .startingVM, generation: record.workerGeneration,
        stage: "the VM to report running")

      #expect(!failed)
      let fresh = try await harness.record(record.id)
      #expect(fresh.state == .waitingForAgent)
      #expect(fresh.failureCode == nil)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) == nil)
      #expect(await harness.metrics.counter(
        name: RunnerVMMetrics.instanceFailuresTotal,
        labels: [
          RunnerVMMetrics.profileLabel: "linux",
          RunnerVMMetrics.codeLabel: "VM_BOOT_TIMEOUT",
        ]) == 0)
      #expect(await worker.shutdownRequests == 0)
    }
  }

  /// The boot deadline is the one piece of a create that only ever lived in memory. A daemon that
  /// restarts mid-boot must rebuild it from `started_at`, or a row whose worker survived sits in
  /// `startingVM` forever, holding cpu, memory, disk and an image pin with nothing bounding it.
  @Test func aRestartRebuildsTheBootDeadlineAndFailsABootThatOverranIt() async throws {
    let config = M2Harness.configuration(vmBoot: .seconds(3))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.state == .startingVM)

      // What a restart loses: the watcher goes with the daemon, the worker and the VM do not.
      await harness.simulateRestart()
      // An hour into a three-second budget. The window is rebuilt from the row, not restarted, so
      // a daemon that keeps crashing cannot hand the same boot a fresh budget every time.
      try await harness.forceInstanceColumn(
        record.id, "started_at", DatabaseDate(Date().addingTimeInterval(-3_600)))

      _ = try await harness.instanceReconciler().run(firstTick: true)

      let failed = try await harness.awaitInstance(record.id, state: .failed)
      #expect(failed.failureCode == "VM_BOOT_TIMEOUT")
      try await waitUntil("the failure record to name the phase that overran") {
        try await harness.instanceStore.failureRecord(instanceId: record.id)?.phase == "startingVM"
      }
    }
  }

  /// The other half of that recovery: a boot still inside its window keeps booting, and the
  /// `running` that arrives after the restart still lands.
  @Test func aRestartLeavesABootInsideItsWindowAlone() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))

      await harness.simulateRestart()
      _ = try await harness.instanceReconciler().run(firstTick: true)

      // Re-armed rather than failed: `started_at` is seconds old against the default 3m budget.
      #expect(try await harness.record(record.id).state == .startingVM)
      #expect(await harness.instances.bootWatchers[record.id] != nil)
      #expect(await harness.supervisor.liveness(id: record.id) == .connected)

      await worker.emit(.running)

      _ = try await harness.awaitInstance(record.id, state: .waitingForAgent)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) == nil)
    }
  }

  /// A guest that came up while runnerd was away has no event left to send: the state it would
  /// have reported already changed. The re-arm asks the worker what it sees before arming anything,
  /// so recovery finishes the boot instead of failing a VM that is already running.
  @Test func aRestartAdoptsAGuestThatCameUpWhileTheDaemonWasAway() async throws {
    let config = M2Harness.configuration(vmBoot: .seconds(3))
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))

      await harness.simulateRestart()
      // The guest boots with nobody listening: the event goes nowhere, and only `worker.hello`
      // still carries the fact.
      await worker.emit(.running)
      // Past the budget too, so a re-arm that ignored the worker would fail this VM outright.
      try await harness.forceInstanceColumn(
        record.id, "started_at", DatabaseDate(Date().addingTimeInterval(-3_600)))

      _ = try await harness.instanceReconciler().run(firstTick: true)

      #expect(try await harness.record(record.id).state == .waitingForAgent)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) == nil)
    }
  }

  /// The window the compare-and-swap exists to lose: `failBootTimeout` reads the row, and by the
  /// time it commits the guest has come up. `waitingForAgent -> failed` is a legal edge, so a
  /// commit that re-read the row instead of carrying the reading it validated would fail a healthy
  /// VM and shut its worker down.
  @Test func aBootLandingBetweenTheReadAndTheCommitKeepsItsVM() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))
      let rows = harness.instanceRows
      let id = record.id
      // Written straight to the row, so the interleaving is exact rather than raced: this is what
      // a `running` event arriving on the worker's event stream would do a moment later.
      await harness.instances.setAfterBootTimeoutRead {
        _ = try? await rows.transition(
          id: id, from: .startingVM, to: .waitingForAgent, expectedGeneration: nil) { _ in }
      }

      let failed = await harness.instances.failBootTimeout(
        id, expecting: .startingVM, generation: record.workerGeneration,
        stage: "the VM to report running")

      #expect(!failed)
      let fresh = try await harness.record(id)
      #expect(fresh.state == .waitingForAgent)
      #expect(fresh.failureCode == nil)
      #expect(try await harness.instanceStore.failureRecord(instanceId: id) == nil)
      #expect(await worker.shutdownRequests == 0)
      #expect(await harness.metrics.counter(
        name: RunnerVMMetrics.instanceFailuresTotal,
        labels: [
          RunnerVMMetrics.profileLabel: "linux",
          RunnerVMMetrics.codeLabel: "VM_BOOT_TIMEOUT",
        ]) == 0)
    }
  }

  /// The same window, one column over: a restart claimed the row and is booting it again. The state
  /// still reads `startingVM`, so only the generation tells the two boots apart -- and this one's
  /// deadline has nothing to say about the new boot's budget.
  @Test func aRespawnBetweenTheReadAndTheCommitKeepsTheNewBoot() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.statesAfterStart = []
      await harness.launcher.set(behaviour)
      let record = try await harness.instances.create(profileName: "linux")
      let worker = try #require(await harness.launcher.worker(for: record.id))
      let rows = harness.instanceRows
      let id = record.id
      await harness.instances.setAfterBootTimeoutRead {
        _ = try? await rows.bumpWorkerGeneration(
          id: id, nonce: "00000000000000000000000000000000", specDigest: "sha256:next")
      }

      let failed = await harness.instances.failBootTimeout(
        id, expecting: .startingVM, generation: record.workerGeneration,
        stage: "the VM to report running")

      #expect(!failed)
      let fresh = try await harness.record(id)
      #expect(fresh.state == .startingVM)
      #expect(fresh.workerGeneration == record.workerGeneration + 1)
      #expect(try await harness.instanceStore.failureRecord(instanceId: id) == nil)
      #expect(await worker.shutdownRequests == 0)
    }
  }

  /// A failure report is evidence, so `fail` writes it only when this call is the one that failed
  /// the row: the state commits first and `failure.json`, the failure metric and the log line all
  /// hang off that compare-and-swap. A row somebody else already owns comes back untouched.
  @Test func failWritesNothingWhenTheRowHasAlreadyMovedOn() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      // Parked in `deleting` -- which has no edge to `failed` -- without tearing anything down, so
      // the directory a `failure.json` would land in is still there to be checked.
      _ = try await harness.instanceRows.transition(
        id: record.id, from: .waitingForAgent, to: .stopping, expectedGeneration: nil) { _ in }
      _ = try await harness.instanceRows.transition(
        id: record.id, from: .stopping, to: .deleting, expectedGeneration: nil) { _ in }

      let landed = await harness.instances.fail(
        record, phase: "startingVM", error: VMError.bootTimeout(stage: "the VM to report running"))

      #expect(!landed)
      #expect(try await harness.record(record.id).state == .deleting)
      #expect(try await harness.instanceStore.failureRecord(instanceId: record.id) == nil)
      #expect(await harness.metrics.counter(
        name: RunnerVMMetrics.instanceFailuresTotal,
        labels: [
          RunnerVMMetrics.profileLabel: "linux",
          RunnerVMMetrics.codeLabel: "VM_BOOT_TIMEOUT",
        ]) == 0)
    }
  }

  @Test func deleteUnlinksTheWorkerSocket() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      let socket = harness.paths.workerSocket(record.id)
      #expect(FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))

      _ = try await harness.instances.delete(id: record.id)

      #expect(!FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
      let agent = harness.paths.agentSocket(record.id)
      #expect(!FileManager.default.fileExists(atPath: agent.path(percentEncoded: false)))
    }
  }
}

@Suite struct InstanceCapacityTests {
  @Test func memoryRejectionIsReportedAsASchedulerError() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(linuxMemory: ByteSize.gibibytes(128).bytes)
    ) { harness in
      try await harness.importLinuxImage()

      await #expect(throws: SchedulerError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }
      #expect(try await harness.instances.list().isEmpty)
    }
  }

  @Test func macOSGuestLimitRejectsAThirdInstance() async throws {
    try await withHarness { harness in
      let linux = try await harness.importLinuxImage()
      try await harness.importMacImage()
      for _ in 0..<2 {
        try await harness.seedInstance(
          profile: "mac", state: .waitingForAgent, digest: linux.record.digest)
      }

      let error = await #expect(throws: SchedulerError.self) {
        _ = try await harness.instances.create(profileName: "mac")
      }
      #expect(error?.code == "SCHEDULER_MACOS_GUEST_LIMIT_REACHED")
    }
  }

  /// The `maxInstances` check and the row that satisfies it are one atomic step: four creates
  /// racing for the last slot must still leave one instance behind (spec §121).
  @Test func concurrentCreatesCannotExceedProfileMaxInstances() async throws {
    try await withHarness(configuration: M2Harness.configuration(maxInstances: 1)) { harness in
      try await harness.importLinuxImage()
      let manager = harness.instances

      let codes = await withTaskGroup(of: String?.self) { group -> [String?] in
        for _ in 0..<4 {
          group.addTask {
            do {
              _ = try await manager.create(profileName: "linux")
              return nil
            } catch {
              return (error as? any RunnerError)?.code ?? "UNKNOWN"
            }
          }
        }
        var results: [String?] = []
        for await code in group { results.append(code) }
        return results
      }

      #expect(codes.count(where: { $0 == nil }) == 1)
      #expect(codes.compactMap { $0 }
        .allSatisfy { $0 == "SCHEDULER_PROFILE_AT_MAX_INSTANCES" })
      #expect(try await harness.instances.list().count == 1)
    }
  }

  @Test func profileMaxInstancesIsHonoured() async throws {
    try await withHarness(configuration: M2Harness.configuration(maxInstances: 1)) { harness in
      let linux = try await harness.importLinuxImage()
      try await harness.seedInstance(
        profile: "linux", state: .waitingForAgent, digest: linux.record.digest)

      let error = await #expect(throws: SchedulerError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }
      #expect(error?.code == "SCHEDULER_PROFILE_AT_MAX_INSTANCES")
    }
  }

  @Test func unknownProfileIsRejectedBeforeAnythingIsWritten() async throws {
    try await withHarness { harness in
      await #expect(throws: SchedulerError.self) {
        _ = try await harness.instances.create(profileName: "nope")
      }
    }
  }

  // MARK: - Reservation pin lifecycle

  /// `images.reserve` pins the digest under `planning` before `create` ever reaches admission;
  /// a rejection there must not leave that pin behind.
  @Test func failedAdmissionReleasesThePlanningPin() async throws {
    try await withHarness(configuration: M2Harness.configuration(maxInstances: 1)) { harness in
      let linux = try await harness.importLinuxImage()
      try await harness.seedInstance(
        profile: "linux", state: .waitingForAgent, digest: linux.record.digest)

      await #expect(throws: SchedulerError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }

      #expect(try await harness.imageRows.pinCount(digest: linux.record.digest) == 0)
    }
  }

  @Test func successfulCreateLeavesOneInstancePinAndNoPlanningPin() async throws {
    try await withHarness { harness in
      let image = try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")

      #expect(try await harness.imageRows.pinCount(digest: image.record.digest) == 1)
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
      let instancePins = try await harness.imageRows.pins(ownerType: .instance)
      #expect(instancePins.map(\.ownerId) == [record.id.rawValue])
    }
  }
}

extension InstanceManager {
  /// Plants the `failBootTimeout` interleaving hook. The property is `internal` on the actor and
  /// only ever set from here, so a race that is otherwise microseconds wide can be described
  /// exactly instead of being chased with a sleep.
  func setAfterBootTimeoutRead(_ hook: (@Sendable () async -> Void)?) {
    afterBootTimeoutRead = hook
  }
}
