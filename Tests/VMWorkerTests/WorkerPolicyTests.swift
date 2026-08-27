import Foundation
import Testing

@testable import vmworker

/// `evaluatePolicy` used to check the lease before the hard deadline, which let a worker whose
/// daemon kept renewing its lease -- or that still had an active bridge connection -- run past
/// `hardDeadline` forever. These pin `WorkerPolicy.decide`'s branch order directly, without a VM.
@Suite struct WorkerPolicyTests {
  private static let epoch = Date(timeIntervalSince1970: 1_756_000_000)

  @Test func hardDeadlineFiresEvenWithALiveLease() {
    let result = WorkerPolicy.decide(
      now: Self.epoch, hardDeadline: Self.epoch.addingTimeInterval(-1),
      leaseExpiresAt: Self.epoch.addingTimeInterval(300), activeConnections: 0,
      orphanIdleSince: nil, orphanIdle: 60)
    #expect(result.decision == .hardDeadline)
  }

  @Test func hardDeadlineFiresEvenWithActiveConnections() {
    let result = WorkerPolicy.decide(
      now: Self.epoch, hardDeadline: Self.epoch.addingTimeInterval(-1),
      leaseExpiresAt: nil, activeConnections: 3, orphanIdleSince: nil, orphanIdle: 60)
    #expect(result.decision == .hardDeadline)
  }

  @Test func noDeadlineAndALiveLeaseIsNone() {
    let result = WorkerPolicy.decide(
      now: Self.epoch, hardDeadline: nil, leaseExpiresAt: Self.epoch.addingTimeInterval(300),
      activeConnections: 0, orphanIdleSince: nil, orphanIdle: 60)
    #expect(result.decision == .none)
    #expect(result.orphanIdleSince == nil)
  }

  @Test func expiredLeaseWithNoConnectionsGoesOrphanAfterTheIdleInterval() {
    let expiredLease = Self.epoch.addingTimeInterval(-10)
    // First poll: nothing idle yet, so the clock starts.
    let first = WorkerPolicy.decide(
      now: Self.epoch, hardDeadline: nil, leaseExpiresAt: expiredLease, activeConnections: 0,
      orphanIdleSince: nil, orphanIdle: 60)
    #expect(first.decision == .none)
    #expect(first.orphanIdleSince == Self.epoch)

    // Not yet past the idle interval.
    let stillWaiting = WorkerPolicy.decide(
      now: Self.epoch.addingTimeInterval(30), hardDeadline: nil, leaseExpiresAt: expiredLease,
      activeConnections: 0, orphanIdleSince: first.orphanIdleSince, orphanIdle: 60)
    #expect(stillWaiting.decision == .none)
    #expect(stillWaiting.orphanIdleSince == Self.epoch)

    // Past it: shut down.
    let timedOut = WorkerPolicy.decide(
      now: Self.epoch.addingTimeInterval(60), hardDeadline: nil, leaseExpiresAt: expiredLease,
      activeConnections: 0, orphanIdleSince: stillWaiting.orphanIdleSince, orphanIdle: 60)
    #expect(timedOut.decision == .orphanIdle)
  }

  @Test func anActiveConnectionResetsTheOrphanClock() {
    let result = WorkerPolicy.decide(
      now: Self.epoch, hardDeadline: nil, leaseExpiresAt: Self.epoch.addingTimeInterval(-10),
      activeConnections: 1, orphanIdleSince: Self.epoch.addingTimeInterval(-120), orphanIdle: 60)
    #expect(result.decision == .none)
    #expect(result.orphanIdleSince == nil)
  }
}
