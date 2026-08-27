import Foundation
import Scheduler

/// Serializes the snapshot → admit → insert sequence that commits host capacity.
///
/// Capacity admission is snapshot arithmetic: `InstanceAdmission` reads every reservation, decides
/// the request fits, and only then writes the row the *next* snapshot will count. Without a
/// critical section spanning all three steps, two creates (or a create and an image build) admitted
/// against the same snapshot both proceed and the host ends up oversubscribed (spec §121).
///
/// One queue serves the whole daemon: instance creation and, from Phase 5, image builds contend
/// for exactly the same budget, so they must contend for exactly the same lock.
public actor AdmissionQueue {
  private struct Waiter {
    let ticket: Int
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var held = false
  private var waiters: [Waiter] = []
  private var nextTicket = 0

  public init() {}

  /// Runs `body` with exclusive ownership of the admission decision. Waiters are served FIFO; a
  /// waiter whose task is cancelled leaves the queue with a `CancellationError` and never runs
  /// `body`, so it cannot delay the ones behind it.
  public func admit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    try await acquire()
    defer { release() }
    return try await body()
  }

  /// Observability for `system.status` and tests: how many callers are queued behind the holder.
  public var queueDepth: Int { waiters.count }

  private func acquire() async throws {
    guard held else {
      held = true
      return
    }
    let ticket = nextTicket
    nextTicket += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        // Cancelled before the waiter was even enqueued: `onCancel` has already run and found
        // nothing, so refuse here rather than parking forever.
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters.append(Waiter(ticket: ticket, continuation: continuation))
      }
    } onCancel: {
      Task { await self.abandon(ticket) }
    }
  }

  private func abandon(_ ticket: Int) {
    // Already resumed: the waiter owns the slot and its own `body` observes the cancellation.
    guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func release() {
    guard !waiters.isEmpty else {
      held = false
      return
    }
    // `held` stays true: ownership passes straight to the next waiter rather than being reopened
    // for whoever happens to call `acquire` first.
    waiters.removeFirst().continuation.resume()
  }
}

/// Capacity held by image builds that are running right now.
///
/// Phase 5's `ImageBuilder` conforms to this; until then every call site passes `nil` and the host
/// totals contain instance reservations only. Kept as a protocol so `Orchestration` does not have
/// to know how builds are tracked — only what they cost.
public protocol ImageBuildReservationSource: Sendable {
  func activeBuildReservations() async throws -> [Reservation]
}
