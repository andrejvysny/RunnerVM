import Foundation
import Metrics
import Persistence
import RunnerCore
import Scheduler

/// Gauge refresh for one scheduling pass (spec §40, §43). Split out of `OrchestratorTick.swift`
/// to keep that file under its line budget; every member runs actor-isolated on `Orchestrator`.
///
/// Gauges are republished wholesale rather than incremented, so a label set that no longer exists
/// — the last `idle` VM of a profile, a worker that went away — disappears from the next scrape
/// instead of freezing at its final value.
extension Orchestrator {
  func refreshMetrics(_ pass: SchedulingPass) async {
    let names = Dictionary(
      pass.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    await metrics.replaceGauge(RunnerVMMetrics.instances, with: instanceGauges(pass, names: names))
    await metrics.replaceGauge(
      RunnerVMMetrics.capacityAdvertised,
      with: pass.profiles.map {
        ([RunnerVMMetrics.profileLabel: $0.name], Double(demandState[$0.id]?.advertisedCapacity ?? 0))
      })
    await metrics.replaceGauge(
      RunnerVMMetrics.demandAssignedJobs,
      with: pass.profiles.map {
        ([RunnerVMMetrics.profileLabel: $0.name], Double($0.assignedJobs))
      })
    await metrics.setGauge(
      RunnerVMMetrics.reservedCPU, to: Double(pass.reservations.reduce(0) { $0 + $1.cpuCount }))
    await metrics.setGauge(
      RunnerVMMetrics.reservedMemoryBytes,
      to: Double(pass.reservations.reduce(0) { $0 + $1.memoryBytes }))
    await metrics.setGauge(
      RunnerVMMetrics.hostFreeDiskBytes, to: Double(Mapping.freeDiskBytes(at: paths.rootDir)))
    await refreshWorkerMetrics(pass, names: names)
  }

  private func instanceGauges(
    _ pass: SchedulingPass, names: [RunnerProfileID: String]
  ) -> [([String: String], Double)] {
    var counts: [[String: String]: Double] = [:]
    for record in pass.instances where record.state != .deleted {
      let labels = [
        RunnerVMMetrics.profileLabel: names[record.profileId] ?? record.profileId.rawValue,
        RunnerVMMetrics.stateLabel: record.state.rawValue,
      ]
      counts[labels, default: 0] += 1
    }
    return counts.map { ($0.key, $0.value) }
  }

  /// Host-observed only (spec §40): this is the `vmworker` process, never the guest. CPU percent
  /// is derived from the difference between two `proc_pidinfo` readings, so the first sample of a
  /// worker publishes RSS but no percentage.
  private func refreshWorkerMetrics(
    _ pass: SchedulingPass, names: [RunnerProfileID: String]
  ) async {
    var rss: [([String: String], Double)] = []
    var cpu: [([String: String], Double)] = []
    var seen: Set<InstanceID> = []
    let sampledAt = now()
    for record in pass.instances {
      guard let pid = record.workerPid, let sample = HostProcessMetrics.sample(pid: pid) else {
        continue
      }
      seen.insert(record.id)
      let labels = [RunnerVMMetrics.instanceLabel: record.id.rawValue]
      rss.append((labels, Double(sample.rssBytes)))
      if let previous = workerCPU[record.id] {
        let elapsed = sampledAt.timeIntervalSince(previous.at)
        if elapsed > 0 {
          cpu.append((labels, (sample.cpuSeconds - previous.cpuSeconds) / elapsed * 100))
        }
      }
      workerCPU[record.id] = (sample.cpuSeconds, sampledAt)
    }
    workerCPU = workerCPU.filter { seen.contains($0.key) }
    await metrics.replaceGauge(RunnerVMMetrics.workerRSSBytes, with: rss)
    await metrics.replaceGauge(RunnerVMMetrics.workerCPUPercent, with: cpu)
  }
}
