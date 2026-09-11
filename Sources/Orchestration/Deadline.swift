import Foundation
import RunnerCore

/// Races `body` against `limit` and reports the loser as `expired()` (spec §73: a profile timeout
/// becomes a typed failure, not a stage that hangs forever).
///
/// HARD RULE: **`body` must be cancellable.** When the deadline wins, the group cancels `body` and
/// then *waits for it* at scope exit before this call returns, so a body that ignores cancellation
/// does not merely leak — it hangs the caller for as long as the work takes, and the timeout is
/// silently useless. In particular never wrap `await task.value` of an unstructured `Task`:
/// `Task.value` is not a cancellation point, so the group parks there until the task finishes on
/// its own (`ActionsServiceConnection.adminConnection` used to, and a 200 ms deadline over it
/// returned after 3.2 s). Everything the body reaches has to be structured concurrency,
/// `URLSession`'s async API, or an explicitly cancellation-aware suspension.
///
/// A non-positive `limit` means "no deadline": `body` runs unwrapped, so a profile that disables a
/// timeout costs nothing.
func withDeadline<T: Sendable>(
  _ limit: DurationValue, expired: @escaping @Sendable () -> any Error,
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  guard limit.isPositive else { return try await body() }
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: limit.duration)
      throw expired()
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw expired() }
    return first
  }
}

/// The cleaning deadline (`timeouts.cleanup`, spec §73). A guest that hangs mid-cleanup must not
/// park the VM in `cleaning` forever.
func withDeadline<T: Sendable>(
  _ timeout: DurationValue, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withDeadline(timeout, expired: { ReuseFailure.timedOut(timeout) }, body)
}
