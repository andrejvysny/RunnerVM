import Foundation
import GuestControl
import Persistence
import RunnerCore

/// The instance-side half of a runner session (spec §47, §48 steps 14-23).
///
/// `RunnerSessionManager` owns the GitHub half and drives these; keeping them on `InstanceManager`
/// means the VM lifecycle still has exactly one owner, and the guest connection is the same
/// `GuestSessions` client `instance.exec` and `instance.metrics` already multiplex over.
extension InstanceManager {
  /// `idle -> configuringRunner`: the only edge that claims an instance for a runner session.
  /// The CAS in `InstanceRepository.transition` is what makes two schedulers racing for the same
  /// idle VM safe — the loser sees `staleWrite`, not a second session.
  public func claimForRunnerSession(id: InstanceID) async throws -> InstanceRecord {
    let record = try await require(id)
    guard record.state == .idle else {
      throw OrchestrationError.instanceNotIdle(id: id.rawValue, state: record.state.rawValue)
    }
    return try await transition(record, to: .configuringRunner)
  }

  /// Follows the session through the VM state machine. Restricted to the runner states so this
  /// cannot become a general-purpose back door into `InstanceState`.
  @discardableResult
  public func advanceRunnerState(
    id: InstanceID, to state: InstanceState
  ) async throws -> InstanceRecord {
    precondition(
      [.runnerStarting, .runnerOnline, .busy].contains(state),
      "advanceRunnerState only drives the runner states")
    let record = try await require(id)
    if record.state == state { return record }
    return try await transition(record, to: state)
  }

  /// A session that ended badly leaves the VM interrupted rather than deleted: its directory is
  /// the only evidence of why the runner never worked (spec §74). The retention sweep in
  /// `InstanceReconciler` removes it later.
  public func abandonForRunnerSession(id: InstanceID, code: String, message: String) async {
    await interrupt(id, code: code, message: message)
  }

  // MARK: - Guest runner control

  /// `singleShot` on the wire: never retried, because a second spawn for the same session id is
  /// answered `ALREADY_STARTED` and a blind retry would hide a real double-start (spec §36).
  public func startRunner(
    id: InstanceID, _ request: StartRunnerRequest
  ) async throws -> StartRunnerResponse {
    try await agentClient(id).startRunner(request)
  }

  public func runnerStatus(id: InstanceID, sessionId: String) async throws -> RunnerStatus {
    try await agentClient(id).runnerStatus(sessionId: sessionId)
  }

  @discardableResult
  public func stopRunner(
    id: InstanceID, sessionId: String, graceMs: Int64
  ) async throws -> StopRunnerResponse {
    try await agentClient(id).stopRunner(
      StopRunnerRequest(sessionId: sessionId, graceMs: graceMs))
  }
}
