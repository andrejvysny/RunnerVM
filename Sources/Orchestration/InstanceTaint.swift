import Foundation
import ImageStore
import Persistence
import RunnerCore
import RunnerLogging

/// Operator- and reconciler-driven reuse controls: taint, image-update retirement, and the
/// restart of an idle reusable VM whose worker died (spec §72, §126, §138).
extension InstanceManager {
  // MARK: - Taint (spec §126)

  /// A tainted VM can never return to `idle`. An idle one is recycled here and now; one that is
  /// mid-session is armed to retire the moment the session ends, because nothing may move the
  /// state of a VM that is running somebody's job.
  @discardableResult
  public func taint(id: InstanceID, reason: String) async throws -> InstanceRecord {
    let record = try await require(id)
    let mid = record.state != .idle && record.state.hasRunningVM
    let updated = try await instances.applyReuse(
      id: id,
      ReuseUpdate(tainted: true, taintReason: reason, retireAfterSession: mid ? true : nil))
    logger.notice(
      "instance tainted",
      metadata: .context(instance: id).merging([
        "reason": .string(reason), "state": .string(record.state.rawValue),
        "retire_after_session": .stringConvertible(mid),
      ]) { $1 })
    guard record.state == .idle else { return updated }
    await recycle(updated, ReuseVerdict(reason: "tainted", taint: nil))
    return (try? await require(id)) ?? updated
  }

  // MARK: - Image updates (spec §138)

  /// A running instance never changes its image identity, but a reusable VM still on the digest
  /// the profile has moved off is retired rather than handed the next job. Idle ones are removed
  /// by the orchestrator's next tick; busy ones go when their session ends.
  ///
  /// Returns how many instances were marked.
  @discardableResult
  public func retireOutdatedReusable() async -> Int {
    guard (configuration?.imageUpdates ?? ImageUpdatesConfig()).recycleReusable,
          let rows = try? await profiles.list() else { return 0 }
    var marked = 0
    for row in rows where row.enabled {
      guard let config = try? row.decodedConfig(), config.lifecycle == .reusable,
            let digest = try? await images.resolve(reference: config.image),
            let records = try? await instances.list(profile: row.id, states: nil)
      else { continue }
      for record in records
      where record.imageDigest != digest && record.state.hasRunningVM && !record.retireAfterSession {
        guard (try? await instances.applyReuse(
          id: record.id, ReuseUpdate(retireAfterSession: true))) != nil else { continue }
        marked += 1
        logger.notice(
          "instance retired by an image update",
          metadata: .context(instance: record.id, imageDigest: digest).merging([
            "profile": .string(row.name), "running_digest": .string(record.imageDigest.rawValue),
          ]) { $1 })
      }
    }
    return marked
  }

  // MARK: - Worker crash recovery (spec §72)

  /// An idle reusable VM whose worker disappeared is restarted from its own disk. Anything else —
  /// ephemeral, mid-job, tainted, out of restart budget, missing disk — is left interrupted or
  /// recycled, because reusing a disk whose VM died under a job is exactly what §72 forbids.
  func restartInterrupted(_ previous: InstanceRecord) async {
    guard previous.lifecycle == .reusable, !previous.tainted,
          Self.reusableRestartStates.contains(previous.state),
          let record = try? await require(previous.id), record.state == .interrupted
    else { return }
    let layout = await instanceStore.layout(for: record.id)
    guard Self.exists(layout.disk), Self.exists(layout.spec) else {
      await recycle(
        record,
        ReuseVerdict(
          reason: "disk-lost", taint: TaintReason.diskLost,
          detail: "the instance disk or spec is gone"))
      return
    }
    // `worker_generation` is the restart budget: the first boot made it 1, so anything past
    // `reuse.maxRestarts` has already been given its second chance.
    guard record.workerGeneration <= (await maxRestarts(for: record)) else {
      await recycle(record, ReuseVerdict(reason: "restart-budget-exhausted"))
      return
    }
    await respawn(record, specPath: layout.spec)
  }

  /// The profile's `reuse.maxRestarts`, or the documented default when the profile row or its
  /// decoded config cannot be found (spec §72).
  private func maxRestarts(for record: InstanceRecord) async -> Int {
    guard let rows = try? await profiles.list(),
          let row = rows.first(where: { $0.id == record.profileId }),
          let config = try? row.decodedConfig()
    else { return ReusePolicy.default.maxRestarts }
    return config.effectiveReuse?.maxRestarts ?? ReusePolicy.default.maxRestarts
  }

  private func respawn(_ record: InstanceRecord, specPath: URL) async {
    // Claiming `startingWorker` is what claims the restart. A worker death arrives twice — once
    // as a lost connection, once from the reconciler — and the caller that loses this CAS must
    // leave the row alone rather than tear down the boot the winner has just started.
    // The agent handshake has to happen again: this is a new boot, with a new boot id.
    guard let starting = try? await transition(record, to: .startingWorker, mutate: { row in
      row.agentReadyAt = nil
      row.failureCode = nil
      row.failureMessage = nil
    }) else { return }
    await supervisor.forget(id: record.id)
    await guests.drop(record.id)
    do {
      let session = try await supervisor.start(instance: starting, specPath: specPath)
      let booting = try await transition(starting, to: .startingVM) { row in
        row.workerPid = session.pid
        row.workerSocket = session.socketPath.path(percentEncoded: false)
        row.startedAt = .now
      }
      logger.notice("reusable instance restarted", metadata: .context(instance: record.id))
      await boot(booting)
    } catch {
      logger.warning(
        "reusable restart failed",
        metadata: .context(instance: record.id).merging([
          "error": .string(String(describing: error)),
        ]) { $1 })
      _ = try? await delete(id: record.id)
    }
  }

  private static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }
}
