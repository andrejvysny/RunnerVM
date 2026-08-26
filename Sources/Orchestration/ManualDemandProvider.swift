import Foundation
import RunnerCore

/// In-memory demand, driven by `debug.demandSet` and by component tests (spec §13).
///
/// Deliberately has no GitHub side at all: it exists so the orchestrator, the capacity math and
/// the session hand-off can be exercised without a scale set, and so an operator can reproduce a
/// scheduling decision on a host with no credential.
public actor ManualDemandProvider: DemandProvider {
  public nonisolated let events: AsyncStream<DemandEvent>

  private let continuation: AsyncStream<DemandEvent>.Continuation
  private var demand: [RunnerProfileID: DemandSnapshot] = [:]
  private var advertised: [RunnerProfileID: Int] = [:]
  private let now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = { Date() }) {
    (events, continuation) = AsyncStream<DemandEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256))
    self.now = now
  }

  public func start() async throws {}

  public func stop() async {
    continuation.finish()
  }

  public func snapshot(profile: RunnerProfileID) async -> DemandSnapshot {
    demand[profile] ?? DemandSnapshot(updatedAt: now())
  }

  public func advertise(profile: RunnerProfileID, capacity: Int) async {
    advertised[profile] = capacity
  }

  public func report() async -> [DemandProviderReport] {
    demand.keys.map { id in
      DemandProviderReport(
        profileId: id, state: "manual", advertisedCapacity: advertised[id] ?? 0,
        snapshot: demand[id] ?? DemandSnapshot(updatedAt: now()))
    }
  }

  public func setDemand(profile: RunnerProfileID, assignedJobs: Int) async throws {
    set(profile: profile, assignedJobs: assignedJobs)
  }

  /// Test-facing spelling of `setDemand`, which cannot be non-throwing because it also witnesses
  /// the protocol requirement the scale-set provider rejects.
  public func set(profile: RunnerProfileID, assignedJobs: Int) {
    demand[profile] = DemandSnapshot(
      assignedJobs: max(0, assignedJobs), updatedAt: now(), healthy: true)
    continuation.yield(.demandChanged(profile: profile))
  }

  /// Lets a test drive the correlation events the scale-set provider would emit from a message.
  public func emit(_ event: DemandEvent) {
    continuation.yield(event)
  }

  public func advertisedCapacity(profile: RunnerProfileID) -> Int {
    advertised[profile] ?? 0
  }
}
