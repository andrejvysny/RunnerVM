import Darwin
import Foundation
import DaemonAPI

/// Host-observed side of spec §40: what the kernel knows about one `vmworker` process.
///
/// `proc_pidinfo` is the cheapest source that needs no entitlement and no child bookkeeping. A
/// refused or recycled pid answers `nil` rather than zeroes, so a caller never reports a plausible
/// but invented figure.
enum HostProcessMetrics {
  static func sample(pid: Int32) -> WorkerProcessMetrics? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    let nanoseconds = Double(info.pti_total_user) + Double(info.pti_total_system)
    return WorkerProcessMetrics(
      pid: pid, rssBytes: info.pti_resident_size, cpuSeconds: nanoseconds / 1_000_000_000)
  }
}
