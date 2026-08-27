import GitHubControl
import Metrics

/// Turns every GitHub HTTP attempt into `runnervm_github_requests_total{class}` (spec §41). The
/// counter was declared long before anything incremented it; this is the one place that does.
public struct MetricsGitHubRequestObserver: GitHubRequestObserver {
  private let metrics: MetricRegistry

  public init(metrics: MetricRegistry) {
    self.metrics = metrics
  }

  public func observe(_ request: GitHubRequest, outcome: GitHubRequestOutcome) async {
    await metrics.increment(
      RunnerVMMetrics.githubRequestsTotal, labels: [RunnerVMMetrics.classLabel: outcome.rawValue])
  }
}
