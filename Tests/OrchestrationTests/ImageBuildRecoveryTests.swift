import DaemonAPI
import Foundation
import ImageStore
import Metrics
import Persistence
import RunnerCore
import Scheduler
import Testing

@testable import Orchestration

/// Restart recovery when the builder VM behind a row cannot be proven dead (W2).
///
/// Every test here turns on a *real* `fcntl` lock held by a *real* child process, because that is
/// the only liveness signal runnerd trusts: `WorkerLock.holderPID` uses `F_GETLK`, POSIX record
/// locks are per-process, and a lock taken inside the test runner would be invisible to it.
@Suite(.serialized)
struct ImageBuildRecoveryTests {
  // MARK: - Fixtures

  private struct Pending {
    var id: ImageBuildID
    var digest: ImageDigest
    var holder: LockHolder
  }

  /// A build row a dead daemon left behind: base pinned, directory on disk, `worker.lock` held by
  /// a live process. `nil` when the host has no `/usr/bin/python3` to hold the lock with.
  private func pendingBuild(
    _ harness: BuildHarness, state: ImageBuildState = .provisioning, nonce: String? = nil
  ) async throws -> Pending? {
    let parent = try await harness.base.importLinuxImage()
    let id = try await harness.seedBuildRow(state: state, name: "pending", workerNonce: nonce)
    try await harness.base.imageRows.pin(
      ownerType: .build, ownerId: id.rawValue, digest: parent.record.digest)
    guard let holder = try LockHolder.start(Self.lock(harness, id)) else { return nil }
    return Pending(id: id, digest: parent.record.digest, holder: holder)
  }

  private static func lock(_ harness: BuildHarness, _ id: ImageBuildID) -> URL {
    VMInstanceLayout.workerLockPath(in: harness.paths.buildVMDir(id))
  }

  /// Binds a worker RPC server exactly where a build's vmworker would publish one.
  private func startWorker(
    _ harness: BuildHarness, for id: ImageBuildID, reporting reported: ImageBuildID? = nil,
    nonce: String = ""
  ) async throws -> FakeWorker {
    try FileManager.default.createDirectory(
      at: harness.paths.buildSocketDir, withIntermediateDirectories: true)
    let worker = FakeWorker(
      socketPath: harness.paths.buildWorkerSocket(id),
      script: FakeWorker.Script(
        generation: 1, nonce: nonce, specDigest: "unused",
        instanceId: InstanceID(rawValue: (reported ?? id).rawValue)))
    try await worker.start()
    return worker
  }

  private func directoryExists(_ harness: BuildHarness, _ id: ImageBuildID) -> Bool {
    FileManager.default.fileExists(
      atPath: harness.paths.buildDir(id).path(percentEncoded: false))
  }

  private func buildPins(_ harness: BuildHarness) async throws -> Int {
    try await harness.base.imageRows.pins(ownerType: .build).count
  }

  // MARK: - Proven dead

  @Test func aBuildWithNoLockHolderIsFailedAndFullyReleased() async throws {
    try await withBuildHarness { harness in
      let parent = try await harness.base.importLinuxImage()
      let id = try await harness.seedBuildRow(state: .provisioning, name: "orphan")
      try await harness.base.imageRows.pin(
        ownerType: .build, ownerId: id.rawValue, digest: parent.record.digest)

      let counts = await harness.builder.recover()
      #expect(counts.terminalized == 1)
      #expect(counts.pending == 0)

      let row = try await harness.row(id.rawValue)
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_INTERRUPTED")
      #expect(row.recoverySince == nil)
      #expect(try await self.buildPins(harness) == 0)
      #expect(!self.directoryExists(harness, id))
    }
  }

  // MARK: - Pending

  @Test func aHeldLockWithNoSocketKeepsEverythingTheBuildReserved() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }

      let counts = await harness.builder.recover()
      #expect(counts.terminalized == 0)
      #expect(counts.pending == 1)

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .provisioning)
      #expect(row.recoverySince != nil)
      #expect(try await self.buildPins(harness) == 1)
      #expect(self.directoryExists(harness, pending.id))

      // The whole point: the host is still committed to this build's cpu/memory/disk, so nothing
      // else can be admitted against it.
      let reservations = try await InstanceAdmission.reservations(
        instances: harness.base.instanceRows,
        profiles: GRDBProfileRepository(db: harness.base.database), builds: harness.builder)
      #expect(reservations.count { $0.isImageBuild } == 1)
      #expect(await harness.base.metrics.gauge(
        name: RunnerVMMetrics.imageBuildsRecoveryPending) == 1)
    }
  }

  @Test func repeatedRecoveryOfAPendingBuildIsIdempotent() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }

      _ = await harness.builder.recover()
      let stamped = try await harness.row(pending.id.rawValue).recoverySince
      #expect(stamped != nil)

      for _ in 0..<2 {
        let counts = await harness.builder.recover()
        #expect(counts.terminalized == 0)
        #expect(counts.pending == 1)
      }

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .provisioning)
      #expect(row.recoverySince == stamped)
      #expect(try await self.buildPins(harness) == 1)
      #expect(self.directoryExists(harness, pending.id))
    }
  }

  @Test func aWorkerReportingAnotherBuildIsNeverAskedToShutDown() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness, nonce: "ours") else { return }
      defer { pending.holder.release() }
      let worker = try await self.startWorker(
        harness, for: pending.id, reporting: ImageBuildID.generate(), nonce: "ours")

      let counts = await harness.builder.recover()
      #expect(counts.pending == 1)
      #expect(await worker.shutdownRequests == 0)

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .provisioning)
      #expect(row.recoverySince != nil)
      #expect(try await self.buildPins(harness) == 1)
      #expect(self.directoryExists(harness, pending.id))
      await worker.stop()
    }
  }

  @Test func aVerifiedWorkerIsAskedToShutDownExactlyOnceAndThenReleasesEverything() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness, nonce: "matching") else { return }
      defer { pending.holder.release() }
      let worker = try await self.startWorker(harness, for: pending.id, nonce: "matching")
      // What a real vmworker does after answering `worker.shutdown`: it exits, and the kernel
      // drops its lock.
      await worker.setExitHandler { [holder = pending.holder] in holder.release() }

      _ = await harness.builder.recover()
      try await waitUntil("the lock holder to exit") { !pending.holder.isRunning }
      _ = await harness.builder.recover()

      #expect(await worker.shutdownRequests == 1)
      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_INTERRUPTED")
      #expect(try await self.buildPins(harness) == 0)
      #expect(!self.directoryExists(harness, pending.id))
      await worker.stop()
    }
  }

  // MARK: - The hard bound

  @Test func aBuildStillUnprovenAtTheDeadlineIsAbandonedButKeepsItsDirectory() async throws {
    let clock = TestClock()
    try await withBuildHarness(customize: { $0.now = { clock.now } }) { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }

      #expect(await harness.builder.recover().pending == 1)
      clock.advance(by: 901)
      let counts = await harness.builder.recover()
      #expect(counts.terminalized == 1)
      #expect(counts.pending == 0)

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_RECOVERY_ABANDONED")
      #expect(try await self.buildPins(harness) == 0)
      // Never deleted: whatever holds the lock may still be writing into it.
      #expect(self.directoryExists(harness, pending.id))
      #expect(pending.holder.isRunning)
    }
  }

  // MARK: - Bounded wait

  @Test func recoveryOfAWorkerThatNeverExitsStillReturnsPromptly() async throws {
    try await withBuildHarness(customize: { $0.recoveryExitWait = (.milliseconds(100), 5) }) {
      harness in
      guard let pending = try await self.pendingBuild(harness, nonce: "wedged") else { return }
      defer { pending.holder.release() }
      // No exit handler: the worker answers `worker.shutdown` and keeps its lock forever.
      let worker = try await self.startWorker(harness, for: pending.id, nonce: "wedged")

      let started = ContinuousClock.now
      let counts = await harness.builder.recover()
      let elapsed = ContinuousClock.now - started

      #expect(elapsed < .seconds(2))
      #expect(counts.pending == 1)
      #expect(await worker.shutdownRequests == 1)
      await worker.stop()
    }
  }

  // MARK: - Cancel

  @Test func cancellingAPendingBuildIsRefusedAndReleasesNothing() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }
      _ = await harness.builder.recover()

      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.cancel(id: pending.id.rawValue)
      }
      #expect(error?.code == "BUILD_WORKER_UNVERIFIABLE")

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .provisioning)
      #expect(try await self.buildPins(harness) == 1)
      #expect(self.directoryExists(harness, pending.id))
    }
  }

  @Test func cancellingABuildWhoseWorkerExitsOnRequestSucceeds() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness, nonce: "cancel-me") else { return }
      defer { pending.holder.release() }
      let worker = try await self.startWorker(harness, for: pending.id, nonce: "cancel-me")
      await worker.setExitHandler { [holder = pending.holder] in holder.release() }

      let response = try await harness.builder.cancel(id: pending.id.rawValue)
      #expect(response.state == "cancelled")

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .cancelled)
      #expect(try await self.buildPins(harness) == 0)
      #expect(!self.directoryExists(harness, pending.id))
      await worker.stop()
    }
  }

  // MARK: - Teardown and capacity

  @Test func shutdownDoesNotBlockOnABuildThisProcessDoesNotOwn() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }
      _ = await harness.builder.recover()

      let started = ContinuousClock.now
      await harness.builder.stop(cancel: true)
      #expect(ContinuousClock.now - started < .seconds(2))

      let row = try await harness.row(pending.id.rawValue)
      #expect(row.state == .provisioning)
      #expect(try await self.buildPins(harness) == 1)
    }
  }

  @Test func aPendingBuildKeepsItsSlotAndItsShareOfTheHostBudget() async throws {
    try await withBuildHarness { harness in
      guard let pending = try await self.pendingBuild(harness) else { return }
      defer { pending.holder.release() }
      #expect(await harness.builder.recover().pending == 1)

      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/true

        """)
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "second"))
      }
      #expect(error?.code == "BUILD_AT_MAX_CONCURRENT")

      let profiles = GRDBProfileRepository(db: harness.base.database)
      let reservations = try await InstanceAdmission.reservations(
        instances: harness.base.instanceRows, profiles: profiles, builds: harness.builder)
      let budget = InstanceAdmission.budget(
        configuration: BuildHarness.configuration(), probe: M2Harness.probe(),
        paths: harness.paths)
      #expect(Double(reservations.reduce(0) { $0 + $1.cpuCount }) <= budget.cpuBudget)
      #expect(reservations.reduce(0) { $0 + $1.memoryBytes } <= budget.memoryBudgetBytes)

      // And a `vm create` planning against the same numbers sees less room than it would with the
      // build gone, which is exactly what stops the host being handed out twice.
      let row = try #require(try await profiles.get(name: "linux"))
      let profile = try row.decodedConfig()
      let idle = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: profile, reservations: [], budget: budget, hostMode: .normal)
      let busy = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: profile, reservations: reservations, budget: budget,
        hostMode: .normal)
      #expect(busy.cap < idle.cap)
    }
  }

  // MARK: - Wire compatibility

  @Test func buildInfoDecodesAPayloadWithoutRecoverySince() throws {
    // Exactly what a daemon still on schema v2 answers `build.get` with.
    let payload = """
      {"buildId":"b1","state":"provisioning","recipePath":"/tmp/Runnerfile",
      "recipeSHA256":"sha256:0","contextPath":"/tmp","fromKind":"image",
      "fromReference":"test-linux","cpuCount":2,"memoryBytes":1073741824,
      "diskBytes":67108864,"diskReservationBytes":67108864,"timeoutMs":60000,
      "buildPath":"/tmp/b1","logPath":"/tmp/b1.log","totalSteps":0,"currentStep":0,
      "createdAt":"2026-08-27T00:00:00.000Z","updatedAt":"2026-08-27T00:00:00.000Z"}
      """
    let decoded = try JSONDecoder().decode(BuildInfoDTO.self, from: Data(payload.utf8))
    #expect(decoded.buildId == "b1")
    #expect(decoded.recoverySince == nil)
  }
}

/// A clock a test moves by hand, for `ImageBuilder.Tuning.now`.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date = Date()) {
    self.value = value
  }

  var now: Date { lock.withLock { value } }

  func advance(by seconds: TimeInterval) {
    lock.withLock { value += seconds }
  }
}
