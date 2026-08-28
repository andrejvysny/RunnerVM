import Foundation
import ImageStore
import Persistence
import RunnerCore
import Testing
import WorkerProtocol

@testable import Orchestration

@Suite struct WorkerSupervisorTests {
  @Test func generationIsBumpedOncePerSpawn() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()

      let record = try await harness.instances.create(profileName: "linux")
      let session = try #require(await harness.supervisor.session(id: record.id))

      #expect(session.generation == 1)
      #expect(session.nonce == record.incarnationNonce)
      #expect(session.specDigest == record.specDigest)
      #expect(session.pid == record.workerPid)
    }
  }

  @Test func mismatchedSpecDigestIsRefused() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.specDigestOverride = String(repeating: "0", count: 64)
      await harness.launcher.set(behaviour)

      let error = await #expect(throws: WorkerSupervisorError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }
      #expect(error?.code == "VM_WORKER_FENCED")
    }
  }

  @Test func aWorkerThatNeverPublishesIsReportedGone() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      var behaviour = FakeWorkerLauncher.Behaviour()
      behaviour.failToPublish = true
      await harness.launcher.set(behaviour)

      await #expect(throws: WorkerSupervisorError.self) {
        _ = try await harness.instances.create(profileName: "linux")
      }
      let record = try #require(try await harness.instances.list().first)
      #expect(record.state == .failed)
      #expect(record.failureCode == "VM_WORKER_SPAWN_FAILED")
    }
  }

  @Test func livenessFollowsTheLockAndTheSocket() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      #expect(await harness.supervisor.liveness(id: record.id) == .connected)
      await harness.supervisor.detach(id: record.id)
      #expect(await harness.supervisor.liveness(id: record.id) == .lockHeldNoSocket)
      await harness.launcher.killWorker(record.id)
      #expect(await harness.supervisor.liveness(id: record.id) == .dead)
    }
  }

  @Test func reconnectAdoptsAWorkerThatStillHoldsItsLock() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")

      // Stands in for a daemon restart: the connection is dropped, the worker keeps serving.
      await harness.supervisor.detach(id: record.id)
      #expect(await harness.supervisor.connectedCount == 0)

      let liveness = await harness.supervisor.reconnectAll(
        instances: try await harness.instances.list())

      #expect(liveness[record.id] == .connected)
      #expect(await harness.supervisor.connectedCount == 1)
      let session = try #require(await harness.supervisor.session(id: record.id))
      #expect(session.generation == record.workerGeneration)
      #expect(session.nonce == record.incarnationNonce)
      #expect(try await harness.record(record.id).state == .waitingForAgent)
    }
  }

  @Test func reconnectRefusesAWorkerFromAnEarlierGeneration() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.supervisor.detach(id: record.id)
      // A row that moved on without the worker noticing.
      _ = try await harness.instanceRows.bumpWorkerGeneration(
        id: record.id, nonce: "ffffffffffffffffffffffffffffffff", specDigest: record.specDigest)

      let liveness = await harness.supervisor.reconnectAll(
        instances: try await harness.instances.list())

      #expect(liveness[record.id] == .lockHeldNoSocket)
      #expect(await harness.supervisor.connectedCount == 0)
    }
  }

  @Test func aDeadWorkerIsReconciledIntoInterrupted() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let record = try await harness.instances.create(profileName: "linux")
      await harness.supervisor.detach(id: record.id)
      await harness.launcher.killWorker(record.id)

      let reconciler = InstanceReconciler(
        instances: harness.instanceRows, manager: harness.instances, supervisor: harness.supervisor,
        store: harness.instanceStore, retention: { .seconds(3_600) })
      let counts = try await reconciler.run(firstTick: true)

      #expect(counts.interrupted == 1)
      #expect(counts.instances == 1)
      #expect(try await harness.record(record.id).state == .interrupted)
    }
  }

  @Test func reconcilerReportsOrphanDirectories() async throws {
    try await withHarness { harness in
      let orphan = harness.paths.instanceDir(InstanceID.generate())
      try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

      let reconciler = InstanceReconciler(
        instances: harness.instanceRows, manager: harness.instances, supervisor: harness.supervisor,
        store: harness.instanceStore, retention: { .seconds(3_600) })

      #expect(try await reconciler.run(firstTick: true).orphans == 1)
      #expect(try await reconciler.run(firstTick: false).orphans == 1)
    }
  }
}

@Suite struct InstanceSpecFileTests {
  /// vmworker decodes these bytes as `VirtualizationCore.VMInstanceSpec`; the two declarations
  /// live in modules that cannot import each other, so the key set is pinned here.
  @Test func jsonKeysMatchTheWorkerContract() throws {
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: "11111111-2222-3333-4444-555555555555"),
      imageDigest: ImageDigest(rawValue: "sha256:" + String(repeating: "a", count: 64)),
      os: .linux, cpuCount: 2, memoryBytes: 2_147_483_648, diskBytes: 4_294_967_296,
      macAddress: "02:11:22:33:44:55", serialConsole: true,
      hardDeadline: Date(timeIntervalSince1970: 1_700_000_000))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    let object = try JSONSerialization.jsonObject(with: try encoder.encode(spec))
    let keys = Set((object as? [String: Any])?.keys ?? [:].keys)

    #expect(
      keys == [
        "id", "imageDigest", "os", "cpuCount", "memoryBytes", "diskBytes", "macAddress",
        "serialConsole", "hardDeadline",
      ])
    let json = String(decoding: try encoder.encode(spec), as: UTF8.self)
    #expect(json.contains("\"hardDeadline\":\"2023-11-14T22:13:20Z\""))
    #expect(json.contains("\"os\":\"linux\""))
  }

  /// The macOS half of the same contract: one extra top-level key, and a nested object whose keys
  /// `VirtualizationCore.MacOSInstancePlatformSpec` has to decode field for field.
  @Test func aMacOSSpecAddsExactlyTheMacOSBlock() throws {
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: "11111111-2222-3333-4444-555555555555"),
      imageDigest: ImageDigest(rawValue: "sha256:" + String(repeating: "a", count: 64)),
      os: .macos, cpuCount: 4, memoryBytes: 2_147_483_648, diskBytes: 4_294_967_296,
      macAddress: "02:11:22:33:44:55",
      macos: MacOSInstancePlatformSpec(
        hardwareModel: "aGFyZHdhcmU=", sourceVersion: "26.0", minimumCPUCount: 4,
        minimumMemoryBytes: 2_147_483_648))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    let object = try #require(
      try JSONSerialization.jsonObject(with: try encoder.encode(spec)) as? [String: Any])

    #expect(
      Set(object.keys) == [
        "id", "imageDigest", "os", "cpuCount", "memoryBytes", "diskBytes", "macAddress",
        "serialConsole", "macos",
      ])
    let macos = try #require(object["macos"] as? [String: Any])
    #expect(
      Set(macos.keys)
        == ["hardwareModel", "sourceVersion", "minimumCPUCount", "minimumMemoryBytes"])
  }

  @Test func absentDeadlineIsOmitted() throws {
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: "abc"), imageDigest: ImageDigest(rawValue: "sha256:x"), os: .linux,
      cpuCount: 1, memoryBytes: 1, diskBytes: 1, macAddress: "02:00:00:00:00:01")
    let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
    #expect(!json.contains("hardDeadline"))
  }

  @Test func generatedMACIsLocallyAdministeredUnicast() {
    for _ in 0..<32 {
      let mac = InstanceSpecFile.randomMACAddress()
      let first = try! #require(UInt8(mac.prefix(2), radix: 16))
      #expect(first & 0x01 == 0)
      #expect(first & 0x02 == 0x02)
      #expect(mac.split(separator: ":").count == 6)
    }
  }
}
