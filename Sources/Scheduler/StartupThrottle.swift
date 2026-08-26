import Foundation
import RunnerCore

/// Startup concurrency is deliberately separate from final capacity: six simultaneous macOS boots
/// degrade a host that would happily run all six once booted (spec §136).
public enum StartupThrottle {
  /// `limit` is `HostConfig.Limits.concurrentVMStarts`. A non-positive limit grants nothing —
  /// config validation is what keeps it at or above 1.
  public static func allowedStarts(pending: Int, inFlightStarts: Int, limit: Int) -> Int {
    let free = limit - max(0, inFlightStarts)
    return max(0, min(max(0, pending), free))
  }
}
