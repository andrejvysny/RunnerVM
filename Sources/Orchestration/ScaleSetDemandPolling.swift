import Foundation
import GitHubControl
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// The message-session half of `ScaleSetDemandProvider`: the long-poll loop, the durable inbox and
/// the replay that runs before a new session opens (spec §45, §49; plan C1 "Demand inbox rule").
///
/// Split out of `ScaleSetDemandProvider.swift` to keep that file under its line budget; every
/// member below runs actor-isolated on the provider exactly as if it were declared there.
extension ScaleSetDemandProvider {
  // MARK: - Poll loop

  /// One task per profile (spec §136: per scale set, never per VM). Actor reentrancy is what makes
  /// this safe — the loop is suspended inside `getMessage` for most of its life, so `advertise`,
  /// `snapshot` and `report` still run.
  func pollLoop(_ profileId: RunnerProfileID, scope: GitHubScope) async {
    var backoff = tuning.initialBackoff
    while !Task.isCancelled {
      do {
        let session = try await ensureSession(profileId, scope: scope)
        guard let state = states[profileId] else { return }
        let message = try await session.getMessage(
          lastMessageID: state.cursor, maxCapacity: state.advertised)
        backoff = tuning.initialBackoff
        markHealthy(profileId)
        guard let message else {
          try await Task.sleep(for: tuning.emptyPollDelay)
          continue
        }
        try await handle(message, profileId: profileId, session: session)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        degrade(profileId, error: error)
        do {
          try await Task.sleep(for: Self.jittered(backoff, fraction: tuning.jitterFraction))
        } catch {
          return
        }
        backoff = Self.grow(backoff, limit: tuning.maxBackoff)
      }
    }
  }

  /// A dropped session is a new connection, so it gets a new generation and a cursor of 0; the
  /// duplicates that follow are caught by the semantic ids in `applied`, not by the cursor.
  private func ensureSession(
    _ profileId: RunnerProfileID, scope: GitHubScope
  ) async throws -> any ScaleSetSession {
    if let session = sessions[profileId] { return session }
    guard let plane = await plane() else {
      throw OrchestrationError.githubNotConfigured(
        reason: "no scale-set control plane is configured")
    }
    guard let state = states[profileId] else {
      throw OrchestrationError.scaleSetNotRegistered(profile: profileId.rawValue)
    }
    if state.sessionState == "closed" { try await rotateGeneration(profileId) }
    let session = try await plane.openSession(
      scope: scope, scaleSetID: state.githubScaleSetId, owner: owner)
    sessions[profileId] = session
    let info = await session.info
    states[profileId]?.sessionState = "open"
    if let current = states[profileId] {
      try? await scaleSets.recordSession(
        scaleSetId: current.scaleSetRowId, generation: current.generation,
        sessionId: info.sessionId, state: "open")
    }
    if let statistics = info.statistics { updateStatistics(statistics, profileId: profileId) }
    return session
  }

  private func rotateGeneration(_ profileId: RunnerProfileID) async throws {
    guard let state = states[profileId] else { return }
    let pending = (try? await scaleSets.pendingIntents(
      scaleSetId: state.scaleSetRowId, generation: state.generation)) ?? []
    // The old queue is gone with the old session: nothing here can still be acknowledged, so the
    // rows are closed locally and any un-acquired job comes back as a redelivery.
    for row in pending {
      try? await scaleSets.markProcessed(
        scaleSetId: state.scaleSetRowId, generation: state.generation, messageId: row.messageId)
    }
    let generation = try await scaleSets.openSession(scaleSetId: state.scaleSetRowId)
    states[profileId]?.generation = generation
    states[profileId]?.cursor = 0
  }

  // MARK: - Message handling (spec §49)

  private func handle(
    _ message: ScaleSetMessage, profileId: RunnerProfileID, session: any ScaleSetSession
  ) async throws {
    if let statistics = message.statistics { updateStatistics(statistics, profileId: profileId) }
    guard let state = states[profileId] else { return }
    try await scaleSets.recordIntent(
      scaleSetId: state.scaleSetRowId, generation: state.generation, messageId: message.messageId,
      messageType: message.messageType, bodyJson: message.body)
    let acquired = try await apply(message, profileId: profileId, session: session)
    if !acquired.isEmpty {
      try await scaleSets.updateIntentBody(
        scaleSetId: state.scaleSetRowId, generation: state.generation,
        messageId: message.messageId,
        bodyJson: Self.envelope(acquired: acquired, body: message.body))
    }
    try await scaleSets.markProcessed(
      scaleSetId: state.scaleSetRowId, generation: state.generation, messageId: message.messageId)
    try await session.deleteMessage(id: message.messageId)
    try await scaleSets.markDeleted(
      scaleSetId: state.scaleSetRowId, generation: state.generation, messageId: message.messageId)
    try await scaleSets.advanceCursor(
      scaleSetId: state.scaleSetRowId, generation: state.generation, messageId: message.messageId)
    let advanced = max(states[profileId]?.cursor ?? 0, message.messageId)
    states[profileId]?.cursor = advanced
  }

  /// Returns the request ids `AcquireJobs` actually granted, so they can be folded into the inbox
  /// row before the message is acknowledged.
  private func apply(
    _ message: ScaleSetMessage, profileId: RunnerProfileID, session: any ScaleSetSession
  ) async throws -> [Int64] {
    var available: [Int64] = []
    for job in message.jobMessages {
      let key = Self.key(job.messageType.rawValue, job.runnerRequestId)
      guard states[profileId]?.applied.contains(key) == false else { continue }
      switch job.messageType {
      case .jobAvailable:
        available.append(job.runnerRequestId)
        // Deliberately not marked applied here: only a granted acquisition retires the id.
        continue
      case .jobAssigned:
        // Assignment is to the scale set, not to a runner (plan C1); the binding arrives with
        // `JobStarted`, which is the message that carries a runner name.
        break
      case .jobStarted:
        emit(
          .jobStarted(
            profile: profileId, runnerName: job.runnerName ?? "",
            requestId: job.runnerRequestId))
      case .jobCompleted:
        emit(
          .jobCompleted(
            profile: profileId, runnerName: job.runnerName ?? "",
            requestId: job.runnerRequestId, result: job.result))
      }
      states[profileId]?.applied.insert(key)
    }
    guard !available.isEmpty else { return [] }
    let acquired = try await session.acquireJobs(requestIDs: available)
    for id in acquired {
      states[profileId]?.applied.insert(Self.key(ScaleSetJobMessage.Kind.jobAvailable.rawValue, id))
    }
    return acquired
  }

  // MARK: - Replay (spec §49 "recover from a daemon crash")

  /// Rebuilds the duplicate-detection set from every inbox row this scale set ever wrote, and
  /// re-drives the correlation half of rows that were recorded but never acknowledged. Returns the
  /// set of `<messageType>:<runnerRequestId>` keys that must not be applied again.
  func replayInbox(
    scaleSetId: String, plane: any ScaleSetControlPlane, scope: GitHubScope
  ) async throws -> Set<String> {
    var applied: Set<String> = []
    let rows = (try? await scaleSets.intents(scaleSetId: scaleSetId)) ?? []
    for row in rows {
      let parsed = Self.parse(body: row.bodyJson)
      for id in parsed.acquired {
        applied.insert(Self.key(ScaleSetJobMessage.Kind.jobAvailable.rawValue, id))
      }
      for job in parsed.jobs where job.type != ScaleSetJobMessage.Kind.jobAvailable.rawValue {
        applied.insert(Self.key(job.type, job.requestId))
      }
      guard row.status == .intent else { continue }
      try? await scaleSets.markProcessed(
        scaleSetId: scaleSetId, generation: row.sessionGeneration, messageId: row.messageId)
    }
    return applied
  }

  // MARK: - Snapshot bookkeeping

  func updateStatistics(_ statistics: ScaleSetStatistics, profileId: RunnerProfileID) {
    guard var state = states[profileId] else { return }
    let assigned = Int(max(0, statistics.totalAssignedJobs))
    let changed = state.snapshot.assignedJobs != assigned
      || state.snapshot.statistics != statistics
      || !state.snapshot.healthy
    state.snapshot = DemandSnapshot(
      assignedJobs: assigned, statistics: statistics, updatedAt: now(), healthy: true)
    state.lastError = nil
    states[profileId] = state
    guard changed else { return }
    emit(.demandChanged(profile: profileId))
  }

  private func markHealthy(_ profileId: RunnerProfileID) {
    guard var state = states[profileId], !state.snapshot.healthy else { return }
    state.snapshot.healthy = true
    state.lastError = nil
    states[profileId] = state
  }

  /// The last known `assignedJobs` is deliberately kept: a scale set that stops answering has not
  /// said its demand is zero, and scaling to zero on a network blip would strand queued jobs.
  private func degrade(_ profileId: RunnerProfileID, error: any Error) {
    let reason = Self.describe(error)
    sessions[profileId] = nil
    states[profileId]?.sessionState = "closed"
    states[profileId]?.lastError = reason
    states[profileId]?.snapshot.healthy = false
    logger.warning(
      "scale set poll failed",
      metadata: .context(profile: profileId).merging(["error": .string(reason)]) { $1 })
    emit(.providerDegraded(profile: profileId, reason: reason))
  }

  // MARK: - Helpers

  static func key(_ messageType: String, _ requestId: Int64) -> String {
    "\(messageType):\(requestId)"
  }

  /// `{"acquired":[…],"messages":<original body>}`. The original body stays verbatim so the row is
  /// still a faithful record of what GitHub sent.
  static func envelope(acquired: [Int64], body: String) -> String {
    let ids = acquired.map(String.init).joined(separator: ",")
    return "{\"acquired\":[\(ids)],\"messages\":\(body)}"
  }

  /// Deliberately `JSONSerialization` rather than `Codable`: replay must survive a body written by
  /// an older build, and a date format it cannot decode must not cost the whole dedupe set.
  static func parse(body: String) -> (acquired: [Int64], jobs: [(type: String, requestId: Int64)]) {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data)
    else { return ([], []) }
    var acquired: [Int64] = []
    var raw: [Any] = []
    if let array = object as? [Any] {
      raw = array
    } else if let wrapper = object as? [String: Any] {
      acquired = (wrapper["acquired"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value }
      raw = wrapper["messages"] as? [Any] ?? []
    }
    let jobs = raw.compactMap { element -> (type: String, requestId: Int64)? in
      guard let entry = element as? [String: Any],
            let type = entry["messageType"] as? String,
            let id = (entry["runnerRequestId"] as? NSNumber)?.int64Value
      else { return nil }
      return (type, id)
    }
    return (acquired, jobs)
  }

  static func jittered(_ backoff: Duration, fraction: Double) -> Duration {
    let millis = max(1, backoff.milliseconds)
    let spread = Int64((Double(millis) * max(0, fraction)).rounded())
    guard spread > 0 else { return backoff }
    return .milliseconds(max(1, millis + Int64.random(in: -spread...spread)))
  }

  static func grow(_ backoff: Duration, limit: Duration) -> Duration {
    min(.milliseconds(max(1, backoff.milliseconds) * 2), limit)
  }
}
