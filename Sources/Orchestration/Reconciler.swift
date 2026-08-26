import Foundation
import Logging
import RunnerLogging

/// What one sweep observed. Reported by `system.status` so an operator can see the daemon is
/// actually looking at the host, not just ticking a counter.
public struct ReconcileCounts: Sendable, Hashable {
  public var instances = 0
  public var workersConnected = 0
  public var interrupted = 0
  public var orphans = 0
  public var swept = 0

  public init() {}
}

/// The work a tick performs. Injected because the reconciler is built before the managers it
/// drives (the daemon socket must exist before any VM does).
public protocol ReconcileStep: Sendable {
  func run(firstTick: Bool) async throws -> ReconcileCounts
}

/// Periodic desired-vs-actual sweep (spec §68, §69).
public actor Reconciler {
  public struct Snapshot: Sendable, Hashable {
    public var lastRunAt: Date?
    public var runCount: Int
    public var errorCount: Int
    public var lastError: String?
    public var counts: ReconcileCounts

    public init(
      lastRunAt: Date? = nil, runCount: Int = 0, errorCount: Int = 0, lastError: String? = nil,
      counts: ReconcileCounts = ReconcileCounts()
    ) {
      self.lastRunAt = lastRunAt
      self.runCount = runCount
      self.errorCount = errorCount
      self.lastError = lastError
      self.counts = counts
    }
  }

  private let logger: Logger
  private var snapshot = Snapshot()
  private var step: (any ReconcileStep)?

  public init(logger: Logger = Logger(component: .reconciler)) {
    self.logger = logger
  }

  public func attach(_ step: any ReconcileStep) {
    self.step = step
  }

  /// Every step must be idempotent (spec §69), so a tick is always safe to repeat.
  public func tick() async {
    let first = snapshot.runCount == 0
    snapshot.runCount += 1
    snapshot.lastRunAt = Date()
    guard let step else {
      logger.debug("reconcile tick", metadata: ["run": .stringConvertible(snapshot.runCount)])
      return
    }
    do {
      snapshot.counts = try await step.run(firstTick: first)
      logger.debug(
        "reconcile tick",
        metadata: [
          "run": .stringConvertible(snapshot.runCount),
          "instances": .stringConvertible(snapshot.counts.instances),
          "workers": .stringConvertible(snapshot.counts.workersConnected),
          "orphans": .stringConvertible(snapshot.counts.orphans),
        ])
    } catch {
      recordFailure(String(describing: error))
    }
  }

  public func recordFailure(_ reason: String) {
    snapshot.errorCount += 1
    snapshot.lastError = reason
    logger.error("reconcile failed", metadata: ["reason": .string(reason)])
  }

  public func state() -> Snapshot { snapshot }
}
