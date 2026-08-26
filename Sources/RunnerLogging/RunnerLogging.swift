// RunnerLogging — swift-log JSON log handler with central secret redaction (spec §42, §117).
import Logging

/// Named subsystems that emit logs. Raw value becomes the JSON `component` field
/// (spec §42 "Required components").
public enum LogComponent: String, Sendable, CaseIterable {
  case daemon
  case github
  case scheduler
  case image
  case workerSupervisor = "worker-supervisor"
  case vmworker
  case guest
  case runner
  case database
  case reconciler
  case metrics
  case rpc
  case cli
}

extension Logger {
  /// Creates a logger labeled with a component name, so `component` in the JSON output
  /// matches one of the required subsystems.
  public init(component: LogComponent) {
    self.init(label: component.rawValue)
  }
}
