import Foundation
import ImageStore
import Metrics
import Persistence
import RunnerCore

/// Restart recovery, run on **every** reconcile tick rather than only the first (B4).
///
/// "A build this process owns" is exactly "an entry in `tasks`". Anything else that is still
/// non-terminal was left behind -- by a daemon that died, or by a `start` whose task never began --
/// and nothing else in the system will ever move it.
///
/// Recovery never *assumes* the builder VM behind such a row is gone. Only a released `fcntl` lock
/// proves that; until it does, the row keeps its state, its host capacity, its base-image pin and
/// its directory, and is reported as pending. Releasing them on an ambiguous verdict would let the
/// host hand the same cpu/memory/disk out twice and let a live vmworker's disk be deleted or
/// hashed underneath it (W2).
extension ImageBuilder {
  @discardableResult
  public func recover() async -> (terminalized: Int, pending: Int) {
    let rows = (try? await builds.list(states: nil)) ?? []
    var terminalized = 0
    var pending = 0
    for row in rows where !row.state.isTerminal && tasks[row.id] == nil {
      if await recover(row) { terminalized += 1 } else { pending += 1 }
    }
    _ = try? await images.sweepStaleBuildPins(knownBuildIDs: Set(rows.map(\.id)))
    sweepOrphanDirectories(known: Set(rows.map(\.id)))
    // Published every tick, zero included, so the series disappears the moment nothing is pending
    // instead of freezing at its last non-zero value.
    await metrics.setGauge(RunnerVMMetrics.imageBuildsRecoveryPending, to: Double(pending))
    return (terminalized, pending)
  }

  /// `true` when the row reached a terminal state on this tick, `false` when it is still pending.
  private func recover(_ row: ImageBuildRecord) async -> Bool {
    let verdict = await probeOrphan(row)
    // Replay runs first and whatever the verdict is: it only registers a digest the store already
    // holds, and touches neither the build directory nor the VM, so even a live worker cannot make
    // it publish anything torn. Discarding the directory afterwards stays gated on proven death.
    if await replaySeal(row, quiet: verdict.isProvenDead) { return true }
    guard verdict.isProvenDead else { return await keepPending(row, verdict: verdict) }
    discard(row.id)
    try? await images.release(build: row.id)
    try? await terminate(row, state: .failed, error: ImageBuildError.interrupted)
    try? await builds.setRecoverySince(id: row.id, nil)
    logger.warning(
      "image build interrupted by a daemon restart",
      metadata: ["build_id": .string(row.id.rawValue), "state": .string(row.state.rawValue)])
    return true
  }

  /// The verdict on whichever vmworker still holds this build's lock, if any.
  func probeOrphan(_ row: ImageBuildRecord) async -> OrphanVerdict {
    let layout = await buildStore.layout(for: row.id)
    return await BuilderWorker.probeOrphan(
      lock: layout.workerLock, socket: paths.buildWorkerSocket(row.id), expectedBuildId: row.id,
      expectedNonce: row.workerNonce, gracefulTimeoutMs: tuning.gracefulShutdownMs,
      exitWait: tuning.recoveryExitWait, logger: logger)
  }

  /// The worker could not be proven dead. Everything the build holds stays held -- that is the
  /// whole point -- and one warning is logged the first time, not once per tick.
  ///
  /// `recoveryDeadline` is the only escape: past it the row is abandoned so a wedged worker cannot
  /// hold a build slot forever. Even then the directory stays, because whatever holds the lock may
  /// still be writing into it; `sweepOrphanDirectories` removes it once the row is purged and the
  /// lock is free.
  private func keepPending(_ row: ImageBuildRecord, verdict: OrphanVerdict) async -> Bool {
    let now = tuning.now()
    guard let since = row.recoverySince?.date else {
      try? await builds.setRecoverySince(id: row.id, DatabaseDate(now))
      logger.warning(
        "image build recovery pending",
        metadata: [
          "build_id": .string(row.id.rawValue), "state": .string(row.state.rawValue),
          "reason": .string(verdict.reason),
        ])
      return false
    }
    guard Duration.seconds(now.timeIntervalSince(since)) >= tuning.recoveryDeadline else {
      return false
    }
    try? await images.release(build: row.id)
    try? await terminate(row, state: .failed, error: ImageBuildError.recoveryAbandoned)
    logger.error(
      "image build abandoned: its worker was never proven dead",
      metadata: [
        "build_id": .string(row.id.rawValue), "state": .string(row.state.rawValue),
        "reason": .string(verdict.reason),
      ])
    return true
  }

  /// A build that crashed *after* the store had the sealed content but *before* the `images` row
  /// landed. `image_digest` was written to the build row first precisely so this is recoverable:
  /// the disk it hashed is gone, so re-sealing is impossible, but registering it is not.
  private func replaySeal(_ row: ImageBuildRecord, quiet: Bool) async -> Bool {
    guard row.state == .sealing, let digest = row.imageDigest,
          await imageStore.exists(digest),
          (try? await images.sealBuildReplay(digest: digest, name: row.name)) != nil
    else { return false }
    if quiet { discard(row.id) }
    try? await images.release(build: row.id)
    try? await terminate(row, state: .succeeded, error: nil)
    logger.info(
      "image build registration replayed after a restart",
      metadata: ["build_id": .string(row.id.rawValue), "image_digest": .string(digest.rawValue)])
    return true
  }

  /// Only ever called once the lock behind `id` is known to be free.
  func discard(_ id: ImageBuildID) {
    Task { try? await buildStore.delete(buildId: id) }
    try? FileManager.default.removeItem(at: paths.buildDir(id))
  }

  /// A directory with no row behind it holds nothing reusable -- a build is never resumed -- so it
  /// is pure leaked disk.
  private func sweepOrphanDirectories(known: Set<ImageBuildID>) {
    guard let directories = try? FileManager.default.contentsOfDirectory(
      at: paths.buildsDir, includingPropertiesForKeys: nil)
    else { return }
    for directory in directories where !directory.lastPathComponent.hasPrefix(".") {
      let id = ImageBuildID(rawValue: directory.lastPathComponent)
      guard !known.contains(id), tasks[id] == nil else { continue }
      let lock = VMInstanceLayout.workerLockPath(in: paths.buildVMDir(id))
      guard ((try? WorkerLock.holderPID(at: lock)) ?? nil) == nil else { continue }
      try? FileManager.default.removeItem(at: directory)
      logger.info("removed orphan build directory", metadata: ["build_id": .string(id.rawValue)])
    }
  }
}

/// Drives `ImageBuilder.recover()` from the daemon's reconcile loop. Every tick, not just the
/// first: a `start` that was admitted and then failed before its task ran leaves exactly the same
/// row a crash does, and the first tick may already be long past (B4).
public struct BuildReconciler: ReconcileStep {
  private let builder: ImageBuilder

  public init(builder: ImageBuilder) {
    self.builder = builder
  }

  public func run(firstTick: Bool) async throws -> ReconcileCounts {
    var counts = ReconcileCounts()
    // Only the rows that actually moved. A pending build is *not* an interruption the daemon
    // handled -- it is capacity still committed to a VM nobody could reach; it is reported through
    // `runnervm_image_builds_recovery_pending` instead.
    counts.interrupted = await builder.recover().terminalized
    return counts
  }
}
