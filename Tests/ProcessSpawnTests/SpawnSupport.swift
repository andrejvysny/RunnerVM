import Darwin
import Foundation
import Testing

/// Fails the test instead of hanging the whole suite: every case here drives a real subprocess,
/// and the bug class this module exists to prevent is "never returns".
struct SpawnHangTimeout: Error, CustomStringConvertible {
  var description: String
}

func withHangGuard<T: Sendable>(
  _ description: String, limit: Duration = .seconds(60),
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: limit)
      throw SpawnHangTimeout(description: "timed out waiting for \(description)")
    }
    guard let first = try await group.next() else {
      throw SpawnHangTimeout(description: "no result while waiting for \(description)")
    }
    group.cancelAll()
    return first
  }
}

/// `true` once `pid` is no longer a child of this process -- the only proof that the single
/// `waitpid` reaped it rather than leaving a zombie for the daemon's lifetime.
func isReaped(_ pid: pid_t) -> Bool {
  var status: Int32 = 0
  let result = waitpid(pid, &status, WNOHANG)
  return result < 0 && errno == ECHILD
}
