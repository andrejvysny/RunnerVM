import Foundation
import ImageStore
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
