import DaemonAPI
import Foundation
import GuestControl
import ImageStore
import Persistence
import RunnerCore
import Scheduler
import Testing

@testable import Orchestration

/// "Kill runnerd at every build phase, then bring it back" as a deterministic in-process test.
///
/// The crash is modelled as a *frozen* daemon rather than a dead one: a `BuildHooks.beforePhase`
/// seam parks the build task on a continuation that is never resumed, so the builder stops writing
/// rows at exactly that point while everything it already created stays on the host -- the pinned
/// base, the materialized directory, and a vmworker still holding the build's `worker.lock` and
/// still answering `worker.hello` with the nonce the row records. A second `ImageBuilder` is then
/// built over the same database, paths, store and admission queue (`restartedBuilder`) and has to
/// converge on its own.
///
/// The lock is a *real* `fcntl` lock held by a *real* child process, because `WorkerLock.holderPID`
/// uses `F_GETLK` and POSIX record locks are per-process: a lock taken inside the test runner would
/// be invisible to the code under test. `LockHolder.start` answers `nil` on a host with no
/// `/usr/bin/python3`, which skips rather than fails.
@Suite(.serialized)
struct ImageBuildFaultInjectionTests {
  /// One `RUN` and one `COPY`, so both provisioning phases are reachable from a single recipe.
  private static let recipe = """
    FROM test-linux
    RUN /bin/echo hi
    COPY app /opt/app

    """

  // MARK: - The parameterised crash

  @Test(arguments: BuildPhase.allCases)
  func aDaemonFrozenAtAnyPhaseConvergesAfterARestart(phase: BuildPhase) async throws {
    let gate = BuildGate(freezingAt: phase)
    try await withBuildHarness(customize: { tuning in
      tuning.hooks.beforePhase = { reached, _ in await gate.arrive(reached) }
    }) { harness in
      do {
        try await Self.crashAndConverge(harness, phase: phase, gate: gate)
      } catch {
        // Never leave the builder parked: `withBuildHarness` tears it down by awaiting its tasks,
        // and a task still sitting on the continuation would hang the whole suite.
        await gate.open()
        throw error
      }
    }
  }

  private static func crashAndConverge(
    _ harness: BuildHarness, phase: BuildPhase, gate: BuildGate
  ) async throws {
    guard let frozen = try await freeze(harness, phase: phase, gate: gate) else { return }
    let restarted = await harness.restartedBuilder { $0.recoveryExitWait = (.milliseconds(10), 5) }
    if frozen.lock != nil {
      try await assertPendingHoldsEverything(harness, restarted: restarted, frozen: frozen)
      await harness.base.launcher.killWorker(InstanceID(rawValue: frozen.id.rawValue))
      frozen.lock?.release()
    }
    _ = await restarted.recover()
    let converged = try await assertConverged(
      harness, restarted: restarted, frozen: frozen, phase: phase)

    // The frozen daemon comes back to life. Nothing it does from here may reach the store or the
    // row the restarted daemon now owns.
    await gate.open()
    await harness.builder.stop(cancel: true)
    try await assertLateResumptionPublishedNothing(
      harness, frozen: frozen, phase: phase, before: converged)
    await frozen.agent.stop()
    await restarted.stop(cancel: true)
  }

  // MARK: - Freeze

  /// What the frozen build left on the host, as a restarted daemon would find it.
  private struct Frozen {
    var id: ImageBuildID
    var name: String
    var agent: FakeGuestAgent
    /// The vmworker that outlived the daemon. `nil` when the phase froze before one existed.
    var lock: LockHolder?
  }

  /// Starts a build and lets it run until the hook for `phase` parks it. `nil` means "skip": the
  /// host has no `python3` to hold a real `worker.lock` with.
  private static func freeze(
    _ harness: BuildHarness, phase: BuildPhase, gate: BuildGate
  ) async throws -> Frozen? {
    try await harness.base.importLinuxImage()
    let recipe = try harness.writeRecipe(Self.recipe)
    try harness.writeContextFile("app/main.sh", contents: "#!/bin/sh\necho hi\n")
    let name = "fault-\(phase.rawValue)"
    let started = try await harness.builder.start(
      ImageBuildRequest(
        recipePath: recipe.deletingLastPathComponent().path(percentEncoded: false), name: name,
        push: phase == .pushing ? "\(harness.base.registry.host)/acme/\(name):v1" : nil))
    let agent = try await harness.startBuildAgent(started.buildId)
    let id = ImageBuildID(rawValue: started.buildId)
    // Bounded generously rather than tightly: this is a hang guard, not a race margin -- the hook
    // fires the instant the ladder reaches the phase.
    try await waitUntil("the build to freeze at \(phase.rawValue)", attempts: 2_000) {
      await gate.arrived
    }
    switch try await holdWorkerLock(harness, id: id) {
    case .noWorker:
      return Frozen(id: id, name: name, agent: agent, lock: nil)
    case let .held(holder):
      return Frozen(id: id, name: name, agent: agent, lock: holder)
    case .noLockAvailable:
      await agent.stop()
      return nil
    }
  }

  private enum SurvivingWorker {
    /// The phase froze before any vmworker was launched.
    case noWorker
    case held(LockHolder)
    /// This host has no `/usr/bin/python3`, so no real `fcntl` lock can be held: skip.
    case noLockAvailable
  }

  /// Pins the fake worker in the state a killed daemon leaves behind: still serving, and still
  /// holding a real `worker.lock` even after it answers `worker.shutdown`. That is the ambiguous
  /// `stillRunning` verdict the restarted daemon must refuse to release anything on.
  private static func holdWorkerLock(
    _ harness: BuildHarness, id: ImageBuildID
  ) async throws -> SurvivingWorker {
    guard let worker = await harness.base.launcher.worker(for: InstanceID(rawValue: id.rawValue))
    else { return .noWorker }
    await worker.setExitHandler {}
    guard let holder = try LockHolder.start(lockURL(harness, id)) else { return .noLockAvailable }
    return .held(holder)
  }

  // MARK: - Pending

  /// While the worker cannot be proven dead the build keeps *everything* it reserved. Releasing any
  /// of it here is how the host hands the same cpu/memory/disk out twice (W2).
  private static func assertPendingHoldsEverything(
    _ harness: BuildHarness, restarted: ImageBuilder, frozen: Frozen
  ) async throws {
    let counts = await restarted.recover()
    #expect(counts.terminalized == 0)
    #expect(counts.pending == 1)

    let row = try await harness.row(frozen.id.rawValue)
    #expect(!row.state.isTerminal)
    #expect(row.recoverySince != nil)
    #expect(try await harness.base.imageRows.pins(ownerType: .build).count == 1)
    #expect(directoryExists(harness, frozen.id))

    let reservations = try await InstanceAdmission.reservations(
      instances: harness.base.instanceRows,
      profiles: GRDBProfileRepository(db: harness.base.database), builds: restarted)
    #expect(reservations.count { $0.isImageBuild } == 1)

    // Capacity is never exceeded: the slot the frozen build holds is not handed out again.
    let second = try harness.writeRecipe("FROM test-linux\nRUN /bin/true\n", in: "second")
    let error = await #expect(throws: ImageBuildError.self) {
      _ = try await restarted.start(
        ImageBuildRequest(recipePath: second.path(percentEncoded: false), name: "second-build"))
    }
    #expect(error?.code == "BUILD_AT_MAX_CONCURRENT")
  }

  // MARK: - Convergence

  /// The state the restarted daemon converged on, so the frozen one can be proven not to change it.
  private struct Converged {
    var state: ImageBuildState
    var failureCode: String?
    var storedDigests: Set<ImageDigest>
    var aliases: [String: ImageDigest]
  }

  private static func assertConverged(
    _ harness: BuildHarness, restarted: ImageBuilder, frozen: Frozen, phase: BuildPhase
  ) async throws -> Converged {
    let row = try await harness.row(frozen.id.rawValue)
    #expect(row.state.isTerminal, "row is \(row.state.rawValue)")
    if phase == .pushing {
      // The crash landed past the point a build is `succeeded` (N4): the image was already sealed
      // and registered, and only the separate push never started.
      #expect(row.state == .succeeded)
      #expect(row.imageDigest != nil)
    } else {
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_INTERRUPTED")
      // Nothing partial escaped into the catalogue for a build that never finished sealing.
      #expect(row.imageDigest == nil)
      #expect(try await harness.base.imageRows.alias(name: frozen.name) == nil)
    }

    #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    #expect(try await restarted.activeBuildReservations().isEmpty)
    #expect(!directoryExists(harness, frozen.id))
    #expect(try WorkerLock.holderPID(at: lockURL(harness, frozen.id)) == nil)
    #expect(
      await harness.base.launcher.worker(for: InstanceID(rawValue: frozen.id.rawValue)) == nil)
    #expect(basePartials(harness).isEmpty)

    let stored = try await assertStoreIsIntact(harness, name: frozen.name)
    // A third pass has nothing left to do, which is what makes recovery safe on every tick.
    let idle = await restarted.recover()
    #expect(idle.terminalized == 0)
    #expect(idle.pending == 0)

    let aliases = try await harness.base.imageRows.aliases()
    return Converged(
      state: row.state, failureCode: row.failureCode, storedDigests: stored,
      aliases: Dictionary(uniqueKeysWithValues: aliases.map { ($0.name, $0.digest) }))
  }

  /// Every blob still hashes to what its manifest claims, nothing is orphaned, and the built name
  /// resolves to at most one image.
  @discardableResult
  private static func assertStoreIsIntact(
    _ harness: BuildHarness, name: String
  ) async throws -> Set<ImageDigest> {
    let stored = try await harness.base.imageStore.list()
    #expect(stored.count { $0.manifest.name == name } <= 1)
    for image in stored { try await harness.base.imageStore.verify(digest: image.digest) }
    #expect(try await harness.base.imageStore.unreferencedBlobs().isEmpty)
    for alias in try await harness.base.imageRows.aliases() {
      #expect(await harness.base.imageStore.exists(alias.digest))
    }
    return Set(stored.map(\.digest))
  }

  // MARK: - The late resumption

  /// The frozen builder finishes its stage ladder after the restarted daemon already owned the row.
  /// Every write it attempts has to lose: `transition` is a compare-and-swap on the old state, and
  /// `terminate` refuses a row that is already terminal.
  private static func assertLateResumptionPublishedNothing(
    _ harness: BuildHarness, frozen: Frozen, phase: BuildPhase, before: Converged
  ) async throws {
    let row = try await harness.row(frozen.id.rawValue)
    #expect(row.state == before.state)
    #expect(row.failureCode == before.failureCode)
    // Counted as well as compared: a second registration of the same content would collapse in a
    // set but must not exist at all.
    let stored = try await harness.base.imageStore.list().map(\.digest)
    #expect(stored.count == before.storedDigests.count)
    #expect(Set(stored) == before.storedDigests)
    #expect(try await harness.base.imageRows.aliases()
      .allSatisfy { before.aliases[$0.name] == $0.digest })
    #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    #expect(!directoryExists(harness, frozen.id))
    try await assertStoreIsIntact(harness, name: frozen.name)

    // Exactly one `build-image` operation, whatever the frozen builder did on its way out.
    let all = try await harness.operations.list(state: nil)
    #expect(all.count { $0.kind == "build-image" && $0.resourceId == frozen.id.rawValue } == 1)

    guard phase == .pushing else {
      #expect(all.count { $0.kind == "push-image" } == 0)
      return
    }
    // The push is a separate operation started once, by whoever finished the build (N4); recovery
    // never starts a second one.
    #expect(all.count { $0.kind == "push-image" } == 1)
    try await waitUntil("the push operation to settle", attempts: 1_200) {
      try await harness.operations.list(state: nil)
        .filter { $0.kind == "push-image" }.allSatisfy { $0.state != .running }
    }
  }

  // MARK: - Phase-specific

  @Test func replayingASealedBuildRegistersOneImageAndNeverASecond() async throws {
    try await withBuildHarness { harness in
      // Content in the store but no `images` row: the window `setImageDigest`-before-delete was
      // ordered to make recoverable (B4).
      let disk = try harness.base.sparseFile(named: "sealed.img", bytes: 8 << 20)
      let sealed = try await harness.base.imageStore.importLocal(
        disk: disk, nvram: nil,
        metadata: ImageMetadata(
          os: .linux, virtualDiskSizeBytes: 8 << 20, createdAt: Date(),
          boot: ImageMetadata.Boot(type: .efi),
          capabilities: ImageMetadata.Capabilities(guestAgent: true)),
        name: "replayed-once")
      let id = try await harness.seedBuildRow(
        state: .sealing, name: "replayed-once", imageDigest: sealed.digest)

      #expect(await harness.builder.recover().terminalized == 1)
      for _ in 0..<2 {
        let again = await harness.builder.recover()
        #expect(again.terminalized == 0)
        #expect(again.pending == 0)
      }

      #expect(try await harness.row(id.rawValue).state == .succeeded)
      #expect(try await harness.base.imageRows.list(state: nil)
        .count { $0.digest == sealed.digest } == 1)
      #expect(try await harness.base.imageRows.aliases().count { $0.name == "replayed-once" } == 1)
      try await Self.assertStoreIsIntact(harness, name: "replayed-once")
    }
  }

  @Test func aFrozenBuilderCannotSealOverTheDirectoryTheRestartedDaemonRemoved() async throws {
    let gate = BuildGate(freezingAt: .storeCommit)
    try await withBuildHarness(customize: { tuning in
      tuning.hooks.beforePhase = { reached, _ in await gate.arrive(reached) }
    }) { harness in
      do {
        guard let frozen = try await Self.freeze(harness, phase: .storeCommit, gate: gate)
        else { return }
        // The seal script has already run in the guest, but nothing has been hashed into the store.
        #expect(try await harness.base.imageStore.list().count { $0.manifest.name == frozen.name } == 0)
        let restarted = await harness.restartedBuilder()
        _ = await restarted.recover()
        #expect(try await harness.row(frozen.id.rawValue).state == .failed)

        await gate.open()
        await harness.builder.stop(cancel: true)
        // The disk it was about to hash is gone, so the only honest outcome is no image at all.
        #expect(try await harness.base.imageStore.list().count { $0.manifest.name == frozen.name } == 0)
        #expect(try await harness.base.imageRows.alias(name: frozen.name) == nil)
        #expect(try await harness.row(frozen.id.rawValue).failureCode == "BUILD_INTERRUPTED")
        try await Self.assertStoreIsIntact(harness, name: frozen.name)
        await frozen.agent.stop()
        await restarted.stop(cancel: true)
      } catch {
        await gate.open()
        throw error
      }
    }
  }

  // MARK: - Helpers

  private static func directoryExists(_ harness: BuildHarness, _ id: ImageBuildID) -> Bool {
    FileManager.default.fileExists(atPath: harness.paths.buildDir(id).path(percentEncoded: false))
  }

  private static func lockURL(_ harness: BuildHarness, _ id: ImageBuildID) -> URL {
    VMInstanceLayout.workerLockPath(in: harness.paths.buildVMDir(id))
  }

  /// Half-finished base-image transfers a killed fetch would leave in the cache directory.
  private static func basePartials(_ harness: BuildHarness) -> [String] {
    let cache = harness.paths.baseImageCacheDir.path(percentEncoded: false)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []
    return names.filter { $0.hasSuffix(".part") }
  }
}

/// A continuation parked inside a `BuildHooks.beforePhase` seam: the in-process stand-in for a
/// daemon that died at exactly one phase. `open()` releases it so the harness can tear the frozen
/// builder down instead of hanging on a task that never returns.
actor BuildGate {
  private let target: BuildPhase
  private var parked: [CheckedContinuation<Void, Never>] = []
  private var opened = false
  /// `true` once the build reached the target phase, which is what a test waits on.
  private(set) var arrived = false

  init(freezingAt target: BuildPhase) {
    self.target = target
  }

  /// The hook body. Every other phase passes straight through, and so does the target once opened
  /// -- a per-step hook like `provisioningRun` fires more than once.
  func arrive(_ phase: BuildPhase) async {
    guard phase == target, !opened else { return }
    arrived = true
    await withCheckedContinuation { parked.append($0) }
  }

  func open() {
    opened = true
    for continuation in parked { continuation.resume() }
    parked.removeAll()
  }
}
