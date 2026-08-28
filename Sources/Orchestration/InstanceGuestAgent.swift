import Foundation
import GuestControl
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// The guest-agent half of `InstanceManager`: the `waitingForAgent -> idle` readiness poll, the
/// boot-id proof after a daemon restart, and the typed calls that need a completed handshake.
///
/// Split out of `InstanceManager.swift` to keep that file under the 500-line budget, exactly as
/// `InstanceCreation.swift` and `InstanceRunnerControl.swift` are. Every member below runs
/// actor-isolated on `InstanceManager` as if it were declared there.
extension InstanceManager {
  /// Guest telemetry and remote commands. Both require a completed handshake: before that the
  /// bridge answers by hanging up, and the caller would see a transport error instead of the real
  /// reason the guest is unreachable.
  public func metrics(id: InstanceID) async throws -> GuestMetrics {
    try await agentClient(id).getMetrics()
  }

  public func guestInfo(id: InstanceID) async throws -> GuestInfo {
    try await agentClient(id).getInfo()
  }

  public func selfTest(id: InstanceID) async throws -> SelfTestResult {
    try await agentClient(id).selfTest()
  }

  public func exec(
    id: InstanceID, _ request: ExecRequest
  ) async throws -> AsyncThrowingStream<ExecEvent, any Error> {
    try await agentClient(id).exec(request)
  }

  func agentClient(_ id: InstanceID) async throws -> GuestAgentClient {
    let record = try await require(id)
    guard record.state.hasRunningVM else {
      throw GuestAgentError.notReady(reason: "instance is \(record.state.rawValue)")
    }
    guard record.agentReadyAt != nil else {
      throw GuestAgentError.notReady(reason: "the guest agent handshake has not completed yet")
    }
    return await guests.client(for: id)
  }

  /// Reconnect after a daemon restart: an instance still waiting simply resumes waiting, while
  /// every instance that claims to hold a boot we handed out has to prove it. A reboot underneath
  /// us voids every session-scoped assumption, so the instance is tainted and interrupted rather
  /// than reused.
  ///
  /// The runner states are checked too, not just `idle`: a VM that rebooted while runnerd was away
  /// has lost the runner its session row still points at, and interrupting it here is what lets
  /// `recoverSessions` see a dead VM instead of re-adopting a session with no runner behind it.
  public func recheckAgents() async {
    guard let records = try? await instances.list(
      profile: nil,
      states: [
        .waitingForAgent, .idle, .cleaning, .configuringRunner, .runnerStarting, .runnerOnline,
        .busy,
      ]) else { return }
    for record in records where !teardown.contains(record.id) {
      switch record.state {
      case .waitingForAgent:
        startReadiness(record.id)
      case .cleaning:
        // Spec §126: nobody is left to finish this cleanup, and an unfinished one can never be
        // called clean, so the VM is recycled rather than resumed.
        await recycle(
          record,
          ReuseVerdict(
            reason: "cleaning-abandoned", taint: TaintReason.cleanupFailed,
            failureCode: "AGENT_CLEANUP_FAILED",
            detail: "runnerd restarted while the VM was being cleaned"))
      default:
        await verifyBootID(record)
      }
    }
  }

  private func verifyBootID(_ record: InstanceRecord) async {
    guard let expected = record.bootId else { return }
    guard let hello = try? await guests.client(for: record.id).hello(),
          hello.bootId != expected else { return }
    let error = GuestAgentError.bootIDChanged(previous: expected, current: hello.bootId)
    await interrupt(record.id, code: error.code, message: error.message, taint: error.message)
  }

  func startReadiness(_ id: InstanceID) {
    guard readiness[id] == nil else { return }
    readiness[id] = Task { [weak self] in await self?.awaitAgent(id) }
  }

  private func awaitAgent(_ id: InstanceID) async {
    let client = await guests.client(for: id)
    let timeout = await agentReadyTimeout(id)
    do {
      let hello = try await client.waitUntilReady(timeout: timeout, policy: tuning.agentReadiness)
      await adopt(hello, id: id)
    } catch is CancellationError {
      // Stop or delete cancelled the poll; the teardown path owns the row from here.
    } catch {
      await failReadiness(id, error: error)
    }
    // Only a poll that ran to its own end clears the slot: a cancelled one may already have been
    // replaced, and removing the successor would let a duplicate start behind it.
    if !Task.isCancelled { readiness.removeValue(forKey: id) }
  }

  private func adopt(_ hello: GuestControl.HelloResponse, id: InstanceID) async {
    guard !teardown.contains(id), let record = try? await require(id),
          record.state == .waitingForAgent else { return }
    _ = try? await transition(record, to: .idle) { record in
      record.bootId = hello.bootId
      record.agentReadyAt = .now
    }
    if let running = vmRunningAt.removeValue(forKey: id) {
      await metrics.observe(
        RunnerVMMetrics.vmRunningToAgentReadySeconds,
        labels: [RunnerVMMetrics.profileLabel: await profileName(record.profileId)],
        since: running)
    }
    logger.info(
      "guest agent ready",
      metadata: .context(profile: record.profileId, instance: id, host: hostId).merging([
        "boot_id": .string(hello.bootId), "agent_version": .string(hello.agentVersion),
      ]) { $1 })
  }

  /// The instance is failed, not deleted: its directory and `failure.json` are the only evidence
  /// of why a guest never came up.
  private func failReadiness(_ id: InstanceID, error: any Error) async {
    guard !teardown.contains(id), let record = try? await require(id),
          record.state == .waitingForAgent else { return }
    await fail(record, phase: "waitingForAgent", error: error)
  }

  private func agentReadyTimeout(_ id: InstanceID) async -> Duration {
    guard let record = try? await require(id),
          let rows = try? await profiles.list(),
          let row = rows.first(where: { $0.id == record.profileId }),
          let config = try? row.decodedConfig() else {
      return TimeoutPolicy.default.agentReady.duration
    }
    return config.effectiveTimeouts.agentReady.duration
  }

  /// Daemon teardown: stop polling and drop every bridge connection. The VMs keep running, and
  /// the next start re-handshakes them through `recheckAgents()`.
  public func detachGuests() async {
    for task in readiness.values { task.cancel() }
    readiness.removeAll()
    await guests.dropAll()
  }

  func releaseGuest(_ id: InstanceID) async {
    readiness.removeValue(forKey: id)?.cancel()
    await guests.drop(id)
  }
}
