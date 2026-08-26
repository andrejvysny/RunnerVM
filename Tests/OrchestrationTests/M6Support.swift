import Foundation
import GitHubControl
import Logging
import Metrics
import Persistence
import RunnerCore
import Synchronization
import Testing

@testable import Orchestration

extension M2Harness {
  var scaleSets: any ScaleSetRepository { GRDBScaleSetRepository(db: database) }
  var sessionRows: any RunnerSessionRepository { GRDBRunnerSessionRepository(db: database) }
  var hosts: any HostRepository { GRDBHostRepository(db: database) }
  var profileRows: any ProfileRepository { GRDBProfileRepository(db: database) }
  var scopeRows: any ScopeRepository { GRDBScopeRepository(db: database) }

  func profileID(_ name: String) async throws -> RunnerProfileID {
    try #require(try await profileRows.get(name: name)).id
  }

  /// The orchestrator wired the way `DaemonRuntime` wires it, minus the reconcile loop: the tests
  /// drive `tick()` themselves so nothing depends on wall-clock timing.
  func orchestrator(
    demand: any DemandProvider,
    configuration: RunnerConfiguration = M2Harness.configuration(),
    tuning: Orchestrator.Tuning = Orchestrator.Tuning(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) async -> Orchestrator {
    let orchestrator = Orchestrator(
      hostId: hostId, paths: paths, probe: M2Harness.probe(), hosts: hosts, profiles: profileRows,
      instanceRows: instanceRows, sessionRows: sessionRows, scaleSets: scaleSets,
      instances: instances, runners: runners, demand: demand, metrics: metrics, tuning: tuning,
      now: now, logger: Logger(label: "test"))
    await orchestrator.updateConfiguration(configuration)
    return orchestrator
  }

  /// Persists the `scale_sets` row the orchestrator reads to decide the JIT source. Registration
  /// against GitHub is `ScaleSetDemandProvider`'s job and is exercised separately.
  @discardableResult
  func registerScaleSet(profile: String, githubScaleSetId: Int64) async throws -> String {
    let id = try await profileID(profile)
    let record = try await scaleSets.ensureScaleSet(
      profileId: id, githubScaleSetName: ScaleSetNaming.name(profile: profile))
    try await scaleSets.updateRegistration(
      scaleSetId: record.id, githubScaleSetId: githubScaleSetId, state: "ready")
    return record.id
  }

  /// A non-terminal session row: the cheapest way to make an instance `bound` for the scheduler
  /// without booting a guest and registering a runner.
  @discardableResult
  func seedSession(
    instance: InstanceID, profile: String, state: RunnerSessionState = .jobRunning
  ) async throws -> RunnerSessionID {
    let id = RunnerSessionID.generate()
    let now = DatabaseDate.now
    try await sessionRows.insert(
      RunnerSessionRecord(
        id: id, instanceId: instance, profileId: try await profileID(profile), jitSource: .rest,
        state: state, createdAt: now, updatedAt: now))
    return id
  }

  func instanceCount(profile: String, states: Set<InstanceState>? = nil) async throws -> Int {
    let id = try await profileID(profile)
    return try await instanceRows.list(profile: id, states: states)
      .count { $0.state != .deleted }
  }

  func demandProvider() -> ScaleSetDemandProvider {
    let plane = scaleSetPlane
    var tuning = ScaleSetDemandProvider.Tuning()
    tuning.initialBackoff = .milliseconds(5)
    tuning.maxBackoff = .milliseconds(20)
    tuning.emptyPollDelay = .milliseconds(5)
    return ScaleSetDemandProvider(
      owner: hostId.rawValue, profiles: profileRows, scopes: scopeRows, scaleSets: scaleSets,
      plane: { plane }, tuning: tuning, logger: Logger(label: "test"))
  }

  /// The repository scope every harness configuration declares.
  static let scope = GitHubScope.repository(owner: "acme", repository: "app")
}

/// Collects a demand provider's event stream so a test can assert on what was emitted. The stream
/// has exactly one consumer, so a test that uses this must not also run an `Orchestrator`.
final class DemandEventLog: Sendable {
  private struct Box: Sendable {
    var events: [DemandEvent] = []
    var task: Task<Void, Never>?
  }

  private let state = Mutex(Box())

  init(_ stream: AsyncStream<DemandEvent>) {
    let task = Task { [self] in
      for await event in stream { append(event) }
    }
    state.withLock { $0.task = task }
  }

  var events: [DemandEvent] { state.withLock { $0.events } }

  func stop() {
    state.withLock { $0.task?.cancel() }
  }

  private func append(_ event: DemandEvent) {
    state.withLock { $0.events.append(event) }
  }
}

func jobMessage(
  _ kind: ScaleSetJobMessage.Kind, request: Int64, runner: String? = nil, result: String? = nil
) -> ScaleSetJobMessage {
  var message = ScaleSetJobMessage(messageType: kind, runnerRequestId: request)
  message.runnerName = runner
  message.result = result
  return message
}

func statistics(assigned: Int64, available: Int64 = 0) -> ScaleSetStatistics {
  ScaleSetStatistics(
    totalAvailableJobs: available, totalAssignedJobs: assigned, totalRunningJobs: 0)
}
