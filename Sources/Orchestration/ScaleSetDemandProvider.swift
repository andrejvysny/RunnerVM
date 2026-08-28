import Foundation
import GitHubControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// One GitHub runner scale set per enabled profile, one long-poll message session per scale set,
/// and a durable inbox in front of every message effect (spec §13, §14, §45, §49, §50).
///
/// Demand is read from `ScaleSetStatistics.totalAssignedJobs` and from nowhere else. Messages
/// exist to acquire jobs and to correlate a runner to a job; counting them would double-count a
/// redelivery, which the protocol explicitly allows (plan C1 "Demand inbox rule").
public actor ScaleSetDemandProvider: DemandProvider {
  public struct Tuning: Sendable {
    public var initialBackoff: Duration = .seconds(1)
    public var maxBackoff: Duration = .seconds(30)
    /// Fraction of the current backoff added as jitter, so several profiles that fail together do
    /// not retry in lockstep (spec §105).
    public var jitterFraction: Double = 0.25
    /// Minimum spacing between registration attempts for a profile that failed to register.
    public var registrationRetry: Duration = .seconds(60)
    /// Spacing after a poll that returned nothing. A real long poll already blocks for ~50 s, so
    /// this only exists so a control plane that answers immediately cannot spin the loop.
    public var emptyPollDelay: Duration = .milliseconds(100)
    /// `_work` is what GitHub itself defaults to; the image lays the runner out to match.
    public var workFolder = "_work"

    public init() {}
  }

  struct ProfileState {
    var name: String
    var scaleSetRowId: String
    var githubScaleSetId: Int64
    var generation: Int
    var cursor: Int64 = 0
    var advertised = 0
    var snapshot = DemandSnapshot()
    var lastError: String?
    var sessionState = "open"
    /// `<messageType>:<runnerRequestId>` for every job message already applied, in any generation.
    var applied: Set<String> = []
  }

  public nonisolated let events: AsyncStream<DemandEvent>

  let continuation: AsyncStream<DemandEvent>.Continuation
  let owner: String
  let profiles: any ProfileRepository
  let scopes: any ScopeRepository
  let scaleSets: any ScaleSetRepository
  let plane: @Sendable () async -> (any ScaleSetControlPlane)?
  let tuning: Tuning
  let now: @Sendable () -> Date
  let logger: Logger

  var states: [RunnerProfileID: ProfileState] = [:]
  var sessions: [RunnerProfileID: any ScaleSetSession] = [:]
  var tasks: [RunnerProfileID: Task<Void, Never>] = [:]
  var registrationFailures: [RunnerProfileID: (at: Date, reason: String)] = [:]
  var running = false

  public init(
    owner: String,
    profiles: any ProfileRepository,
    scopes: any ScopeRepository,
    scaleSets: any ScaleSetRepository,
    plane: @escaping @Sendable () async -> (any ScaleSetControlPlane)?,
    tuning: Tuning = Tuning(),
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger = Logger(component: .github)
  ) {
    (events, continuation) = AsyncStream<DemandEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(512))
    self.owner = owner
    self.profiles = profiles
    self.scopes = scopes
    self.scaleSets = scaleSets
    self.plane = plane
    self.tuning = tuning
    self.now = now
    self.logger = logger
  }

  // MARK: - Lifecycle

  public func start() async throws {
    guard !running else { return }
    running = true
    await refresh()
  }

  public func stop() async {
    running = false
    for task in tasks.values { task.cancel() }
    for task in tasks.values { await task.value }
    tasks.removeAll()
    for (profileId, session) in sessions {
      try? await session.close()
      states[profileId]?.sessionState = "closed"
      if let state = states[profileId] {
        try? await scaleSets.recordSession(
          scaleSetId: state.scaleSetRowId, generation: state.generation, sessionId: nil,
          state: "closed")
      }
    }
    sessions.removeAll()
    continuation.finish()
  }

  /// Picks up profiles a `config.apply` added, drops the ones it disabled, and retries the ones
  /// whose registration failed. Called at start and from every orchestrator tick, so it must stay
  /// cheap for the steady state — both loops below are empty once the set of profiles is stable.
  public func refresh() async {
    guard running, let plane = await plane() else { return }
    guard let rows = try? await profiles.list(), let scopeRows = try? await scopes.list() else {
      return
    }
    let enabled = Set(rows.lazy.filter(\.enabled).map(\.id))
    for profileId in states.keys where !enabled.contains(profileId) {
      await retire(profileId)
    }
    let scopesById = Dictionary(scopeRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for row in rows where row.enabled && states[row.id] == nil {
      guard let scopeRow = scopesById[row.scopeId], scopeRow.enabled,
            scopeRow.health == GitHubMapping.healthy, shouldRetryRegistration(row.id)
      else { continue }
      await register(row, scopeRecord: scopeRow, plane: plane)
    }
  }

  /// Closes and forgets one profile's message session, the mirror of `register`.
  ///
  /// `refresh()` used to only ever *add*, so a profile `config.apply` disabled kept its session
  /// for the life of the process — and a scale set has exactly one session, so that daemon went on
  /// taking job messages for a profile it no longer runs. Seen live: a second host on the same
  /// repository held `runnervm-ubuntu-24` open after its profile was disabled and captured a job
  /// the deployed host was locked out of (`HTTP 409 RunnerScaleSetSessionConflictException`).
  ///
  /// Cancelling before closing matters: `ensureSession` re-opens a missing session at the top of
  /// every poll, so closing first would just hand the loop a fresh one.
  private func retire(_ profileId: RunnerProfileID) async {
    if let task = tasks.removeValue(forKey: profileId) {
      task.cancel()
      await task.value
    }
    if let session = sessions.removeValue(forKey: profileId) { try? await session.close() }
    registrationFailures.removeValue(forKey: profileId)
    guard let state = states.removeValue(forKey: profileId) else { return }
    try? await scaleSets.recordSession(
      scaleSetId: state.scaleSetRowId, generation: state.generation, sessionId: nil,
      state: "closed")
    logger.info(
      "scale set session retired",
      metadata: .context(profile: profileId, scaleSetID: state.scaleSetRowId).merging([
        "scale_set": .string(state.name), "generation": .stringConvertible(state.generation),
      ]) { $1 })
  }

  private func shouldRetryRegistration(_ id: RunnerProfileID) -> Bool {
    guard let failure = registrationFailures[id] else { return true }
    let parts = tuning.registrationRetry.components
    return now().timeIntervalSince(failure.at) >= Double(parts.seconds)
  }

  // MARK: - Registration (spec §14, §48 steps 1-2)

  private func register(
    _ row: RunnerProfileRecord, scopeRecord: GitHubScopeRecord, plane: any ScaleSetControlPlane
  ) async {
    let name = ScaleSetNaming.name(profile: row.name)
    do {
      let scope = try GitHubMapping.scope(scopeRecord)
      let record = try await scaleSets.ensureScaleSet(
        profileId: row.id, githubScaleSetName: name)
      let info = try await plane.ensureScaleSet(
        scope: scope, name: name, runnerGroupID: scope.runnerGroupID,
        labels: [row.name], disableUpdate: true)
      try await scaleSets.updateRegistration(
        scaleSetId: record.id, githubScaleSetId: info.id, state: "ready")
      let applied = try await replayInbox(scaleSetId: record.id, plane: plane, scope: scope)
      let generation = try await scaleSets.openSession(scaleSetId: record.id)
      states[row.id] = ProfileState(
        name: row.name, scaleSetRowId: record.id, githubScaleSetId: info.id,
        generation: generation,
        snapshot: DemandSnapshot(
          assignedJobs: Int(info.statistics?.totalAssignedJobs ?? 0), statistics: info.statistics,
          updatedAt: now(), healthy: true,
          // Registration statistics may trail the session's view; the first poll confirms them.
          confirmed: false),
        applied: applied)
      registrationFailures[row.id] = nil
      logger.info(
        "scale set ready",
        metadata: .context(profile: row.id, scaleSetID: record.id).merging([
          "scale_set": .string(name), "github_scale_set_id": .stringConvertible(info.id),
          "generation": .stringConvertible(generation),
        ]) { $1 })
      tasks[row.id] = Task { [weak self] in await self?.pollLoop(row.id, scope: scope) }
    } catch {
      let reason = Self.describe(error)
      registrationFailures[row.id] = (at: now(), reason: reason)
      logger.warning(
        "scale set registration failed",
        metadata: .context(profile: row.id).merging([
          "scale_set": .string(name), "error": .string(reason),
        ]) { $1 })
      continuation.yield(.providerDegraded(profile: row.id, reason: reason))
    }
  }

  // MARK: - DemandProvider

  public func snapshot(profile: RunnerProfileID) async -> DemandSnapshot {
    states[profile]?.snapshot ?? DemandSnapshot(updatedAt: now(), healthy: false)
  }

  public func advertise(profile: RunnerProfileID, capacity: Int) async {
    states[profile]?.advertised = max(0, capacity)
  }

  public func report() async -> [DemandProviderReport] {
    var result: [DemandProviderReport] = []
    for (profileId, state) in states {
      let session = try? await scaleSets.currentSession(scaleSetId: state.scaleSetRowId)
      result.append(
        DemandProviderReport(
          profileId: profileId, scaleSetName: ScaleSetNaming.name(profile: state.name),
          githubScaleSetId: state.githubScaleSetId, state: "ready",
          sessionState: state.sessionState, sessionGeneration: state.generation,
          lastMessageId: session?.lastMessageId ?? state.cursor,
          advertisedCapacity: state.advertised, snapshot: state.snapshot,
          lastError: state.lastError))
    }
    for (profileId, failure) in registrationFailures where states[profileId] == nil {
      result.append(
        DemandProviderReport(
          profileId: profileId, state: "failed",
          snapshot: DemandSnapshot(updatedAt: failure.at, healthy: false),
          lastError: failure.reason))
    }
    return result.sorted { $0.profileId.rawValue < $1.profileId.rawValue }
  }

  // MARK: - Internals shared with the polling extension

  func emit(_ event: DemandEvent) {
    continuation.yield(event)
  }

  static func describe(_ error: any Error) -> String {
    guard let error = error as? any RunnerError else { return String(describing: error) }
    return "\(error.code): \(error.message)"
  }
}
