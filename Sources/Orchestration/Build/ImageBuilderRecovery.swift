import Foundation
import ImageStore
import Persistence
import RunnerCore

/// Restart recovery, run on **every** reconcile tick rather than only the first (B4).
///
/// "A build this process owns" is exactly "an entry in `tasks`". Anything else that is still
/// non-terminal was left behind -- by a daemon that died, or by a `start` whose task never began --
/// and nothing else in the system will ever move it.
extension ImageBuilder {
  @discardableResult
  public func recover() async -> Int {
    let rows = (try? await builds.list(states: nil)) ?? []
    var recovered = 0
    for row in rows where !row.state.isTerminal && tasks[row.id] == nil {
      await recover(row)
      recovered += 1
    }
    _ = try? await images.sweepStaleBuildPins(knownBuildIDs: Set(rows.map(\.id)))
    sweepOrphanDirectories(known: Set(rows.map(\.id)))
    return recovered
  }

  private func recover(_ row: ImageBuildRecord) async {
    let layout = await buildStore.layout(for: row.id)
    let quiet = await BuilderWorker.terminateOrphan(
      lock: layout.workerLock, socket: paths.buildWorkerSocket(row.id), expectedBuildId: row.id,
      expectedNonce: row.workerNonce, gracefulTimeoutMs: tuning.gracefulShutdownMs, logger: logger)
    if await replaySeal(row, quiet: quiet) { return }
    if quiet { discard(row.id) }
    try? await images.release(build: row.id)
    try? await terminate(row, state: .failed, error: ImageBuildError.interrupted)
    logger.warning(
      "image build interrupted by a daemon restart",
      metadata: ["build_id": .string(row.id.rawValue), "state": .string(row.state.rawValue)])
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

  private func discard(_ id: ImageBuildID) {
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
    counts.interrupted = await builder.recover()
    return counts
  }
}
