import Foundation

/// How one HTTP attempt against GitHub ended, coarse enough to be a metric label.
///
/// One observation per *attempt*, not per logical call: a request the retry policy replays three
/// times is three observations, which is what an operator watching a rate-limit or an outage
/// wants to see climb.
public enum GitHubRequestOutcome: String, Sendable, CaseIterable {
  /// 2xx.
  case success
  /// 429, or 403 carrying a rate-limit body (`GitHubErrorMapper` decides).
  case rateLimited = "rate_limited"
  /// Any other 4xx.
  case clientError = "client_error"
  /// 5xx.
  case serverError = "server_error"
  /// The request never produced an HTTP response: DNS, connect, TLS, timeout, cancellation.
  case transport
  /// 2xx whose body did not decode as the expected shape.
  case decode
}

/// Hook for request accounting. `GitHubControl` deliberately knows nothing about the metrics
/// module; the daemon supplies an adapter that turns outcomes into
/// `runnervm_github_requests_total{class}`.
public protocol GitHubRequestObserver: Sendable {
  func observe(_ request: GitHubRequest, outcome: GitHubRequestOutcome) async
}
