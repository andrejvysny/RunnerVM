import Foundation
@testable import GitHubControl
import RunnerCore
import Synchronization
import Testing

/// Records the delays the retry loop asks for instead of waiting them out, so the reliability
/// tests assert the schedule without spending wall-clock time.
final class SleepLog: Sendable {
  private let storage = Mutex<[Duration]>([])

  var durations: [Duration] {
    storage.withLock { $0 }
  }

  func record(_ duration: Duration) {
    storage.withLock { $0.append(duration) }
  }
}

enum Fixture {
  static let token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"
  /// Fixed clock: `x-ratelimit-reset` is an absolute epoch, so "now" must be known.
  static let now = Date(timeIntervalSince1970: 1_700_000_000)
  static let repositoryScope = GitHubScope.repository(owner: "acme", repository: "project-a")
  static let organizationScope = GitHubScope.organization(owner: "acme", runnerGroupID: 7)

  static let policy = RetryPolicy(
    maxAttempts: 3, baseDelay: .seconds(1), maxDelay: .seconds(60), jitter: 0.2, multiplier: 2
  )

  static let runnerJSON = """
  {"id":42,"name":"runnervm-abc","os":"linux","status":"online","busy":false,\
  "labels":[{"id":1,"name":"self-hosted","type":"read-only"},{"id":2,"name":"ubuntu-24","type":"custom"}]}
  """
}

struct Harness {
  let server: FakeGitHubServer
  let client: GitHubHTTPClient
  let api: GitHubRunnersAPI
  let sleeps: SleepLog
}

/// Builds a client bound to an in-process fake: no sockets, no sleeping, no randomness.
func withHarness(
  token: String = Fixture.token,
  policy: RetryPolicy = Fixture.policy,
  maxRetryAfter: Duration = .seconds(120),
  now: Date = Fixture.now,
  observer: (any GitHubRequestObserver)? = nil,
  _ body: (Harness) async throws -> Void
) async throws {
  let server = FakeGitHubServer()
  defer { server.shutdown() }
  let sleeps = SleepLog()
  let client = GitHubHTTPClient(
    baseURL: server.baseURL,
    credentials: StaticCredentialProvider(token: token),
    session: server.makeSession(),
    options: GitHubHTTPClient.Options(retryPolicy: policy, maxRetryAfter: maxRetryAfter),
    observer: observer,
    sleep: { sleeps.record($0) },
    // Pin jitter to its midpoint so the expected schedule is exact.
    random: { _ in 1.0 },
    now: { now }
  )
  try await body(
    Harness(server: server, client: client, api: GitHubRunnersAPI(client: client), sleeps: sleeps)
  )
}

/// Collects `GitHubRequestObserver` outcomes in call order.
final class RecordingRequestObserver: GitHubRequestObserver, Sendable {
  private let recorded = Mutex<[GitHubRequestOutcome]>([])

  var outcomes: [GitHubRequestOutcome] { recorded.withLock { $0 } }

  func observe(_ request: GitHubRequest, outcome: GitHubRequestOutcome) async {
    recorded.withLock { $0.append(outcome) }
  }
}

func errorClass(of error: any Error) -> GitHubErrorClass? {
  (error as? GitHubControlError)?.errorClass
}

/// Captures the error a throwing async call produced, for assertions Swift Testing's `#expect(throws:)`
/// cannot make (classification, `retryable`).
func captureError(_ body: () async throws -> Void) async -> (any Error)? {
  do {
    try await body()
    return nil
  } catch {
    return error
  }
}
