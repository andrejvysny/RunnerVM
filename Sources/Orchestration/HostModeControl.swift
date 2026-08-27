import DaemonAPI
import Foundation
import Logging
import Persistence
import RPC
import RunnerCore
import RunnerLogging

/// Operator control over `hosts.mode` (spec §108, §109).
///
/// Every move is a compare-and-swap against the persisted row, so two `runnerctl` invocations
/// racing each other cannot leave the host in a mode neither asked for; the orchestrator re-reads
/// the row on every tick and stops advertising capacity the moment it says `draining`.
public actor HostModeControl {
  public struct Report: Sendable, Hashable {
    public var mode: HostMode
    /// Runner sessions that have not reached a terminal state.
    public var activeSessions: Int
    /// False only when a caller asked to wait and the timeout fired first.
    public var drained: Bool

    public init(mode: HostMode, activeSessions: Int, drained: Bool) {
      self.mode = mode
      self.activeSessions = activeSessions
      self.drained = drained
    }
  }

  /// How often `wait` re-reads the session rows. Sessions end on the observer's poll cadence, so
  /// anything finer just burns a query.
  static let pollInterval: Duration = .milliseconds(250)

  private let hostId: HostID
  private let hosts: any HostRepository
  private let sessions: any RunnerSessionRepository
  private let audit: any AuditRepository
  private let actorName: String
  /// In-flight image builds. A build owns a VM producing an artifact and cannot be handed to
  /// another host, so a drain has to wait it out exactly like a runner session; it is a separate
  /// closure (rather than folded into the session count) because `Report.activeSessions` is what
  /// `runnerctl system drain` prints, and a build is not a session.
  private let builds: @Sendable () async -> Int
  private let logger: Logger

  public init(
    hostId: HostID, hosts: any HostRepository, sessions: any RunnerSessionRepository,
    audit: any AuditRepository, actorName: String,
    builds: @escaping @Sendable () async -> Int = { 0 },
    logger: Logger = Logger(component: .daemon)
  ) {
    self.hostId = hostId
    self.hosts = hosts
    self.sessions = sessions
    self.audit = audit
    self.actorName = actorName
    self.builds = builds
    self.logger = logger
  }

  // MARK: - Queries

  public func mode() async throws -> HostMode {
    try await hosts.mode(id: hostId)
  }

  public func report() async throws -> Report {
    Report(mode: try await mode(), activeSessions: await activeSessions(), drained: false)
  }

  public func activeSessions() async -> Int {
    let rows = (try? await sessions.list(limit: nil)) ?? []
    return rows.count { !$0.state.isTerminal }
  }

  /// Everything a drain has to outlive: runner sessions plus in-flight image builds.
  public func activeWork() async -> Int {
    await activeSessions() + builds()
  }

  // MARK: - Transitions

  /// Idempotent: draining an already-draining host is a no-op that still reports the session
  /// count, which is what an operator polling the command actually wants.
  @discardableResult
  public func drain() async throws -> Report {
    let current = try await mode()
    switch current {
    case .normal: try await move(from: .normal, to: .draining)
    case .draining: break
    case .offline:
      throw DaemonServiceError.unavailable(
        reason: "the host is offline; run `runnerctl system resume` before draining")
    }
    return Report(mode: .draining, activeSessions: await activeSessions(), drained: false)
  }

  @discardableResult
  public func resume() async throws -> Report {
    let current = try await mode()
    if current != .normal { try await move(from: current, to: .normal) }
    return Report(mode: .normal, activeSessions: await activeSessions(), drained: true)
  }

  /// `normal -> offline` is not an edge of the state machine, so a host that has not been drained
  /// yet is drained first — one command, two audited transitions.
  @discardableResult
  public func offline() async throws -> Report {
    var current = try await mode()
    if current == .normal {
      try await move(from: .normal, to: .draining)
      current = .draining
    }
    if current == .draining { try await move(from: .draining, to: .offline) }
    return Report(mode: .offline, activeSessions: await activeSessions(), drained: true)
  }

  /// Blocks until the last active session ends or the deadline passes. The mode is not changed
  /// here: the caller has already put the host in `draining`, which is what stops new work.
  public func waitForIdle(timeout: Duration) async -> Report {
    let deadline = ContinuousClock.now + timeout
    var loggedBuildWait = false
    while ContinuousClock.now < deadline {
      let sessions = await activeSessions()
      let running = await builds()
      if sessions == 0, running == 0 {
        return Report(
          mode: (try? await mode()) ?? .draining, activeSessions: 0, drained: true)
      }
      if sessions == 0, running > 0, !loggedBuildWait {
        loggedBuildWait = true
        logger.notice(
          "drain is waiting for in-flight image builds",
          metadata: ["builds": .stringConvertible(running)])
      }
      do { try await Task.sleep(for: Self.pollInterval) } catch { break }
    }
    let remaining = await activeWork()
    return Report(
      mode: (try? await mode()) ?? .draining, activeSessions: await activeSessions(),
      drained: remaining == 0)
  }

  // MARK: - Internals

  /// Audited: taking a host out of service is an operator action that has to survive in
  /// `audit_events`, not just in the log.
  private func move(from: HostMode, to: HostMode) async throws {
    do {
      try await hosts.setMode(id: hostId, from: from, to: to)
    } catch let error as any RunnerError {
      throw DaemonServiceError.unavailable(
        reason: "cannot move the host from \(from.rawValue) to \(to.rawValue): \(error.message)")
    }
    try? await audit.record(
      kind: "host.mode", actor: actorName, resourceType: "host", resourceId: hostId.rawValue,
      detail: JSONValue.object(["from": .string(from.rawValue), "to": .string(to.rawValue)])
        .encodedString())
    logger.notice(
      "host mode changed",
      metadata: ["from": .string(from.rawValue), "to": .string(to.rawValue)])
  }
}
