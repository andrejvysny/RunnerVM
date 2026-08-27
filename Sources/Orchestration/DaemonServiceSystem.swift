import DaemonAPI
import Foundation
import Metrics
import Persistence
import RunnerCore

/// `system.drain` / `resume` / `offline` / `shutdown` and `metrics.snapshot` (spec §43, §108,
/// §109). Split out of `DaemonServiceImpl.swift` to keep that file under its line budget; every
/// member below runs actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  // MARK: - Host mode

  func systemDrain(_ request: SystemDrainRequest) async throws -> SystemModeResponse {
    var report = try await hostMode.drain()
    // `activeWork`, not `activeSessions`: an in-flight image build owns a VM this host cannot hand
    // to anyone else, so a drain has to outlive it too.
    if request.wait, await hostMode.activeWork() > 0 {
      report = await hostMode.waitForIdle(timeout: .milliseconds(max(0, request.timeoutMs)))
    }
    return Self.response(report)
  }

  func systemResume() async throws -> SystemModeResponse {
    Self.response(try await hostMode.resume())
  }

  func systemOffline() async throws -> SystemModeResponse {
    Self.response(try await hostMode.offline())
  }

  /// Spec §108. Drains first either way, so nothing new is admitted while the daemon winds down;
  /// without `force` a still-running job aborts the shutdown rather than being interrupted.
  func systemShutdown(_ request: SystemShutdownRequest) async throws -> SystemShutdownResponse {
    guard let handler = shutdownHandler else {
      throw DaemonServiceError.unavailable(reason: "this daemon cannot shut itself down")
    }
    var report = try await hostMode.drain()
    if !request.force, await hostMode.activeWork() > 0 {
      report = await hostMode.waitForIdle(timeout: .milliseconds(max(0, request.timeoutMs)))
      guard report.drained else {
        throw DaemonServiceError.unavailable(
          reason:
            "\(report.activeSessions) runner session(s) still active; retry or use --force")
      }
    }
    let force = request.force
    // Handed off rather than awaited: stopping the runtime tears down the very socket this reply
    // has to travel over.
    Task { await handler(force) }
    return SystemShutdownResponse(
      accepted: true, mode: report.mode.rawValue, activeSessions: report.activeSessions)
  }

  private static func response(_ report: HostModeControl.Report) -> SystemModeResponse {
    SystemModeResponse(
      mode: report.mode.rawValue, activeSessions: report.activeSessions, drained: report.drained)
  }

  // MARK: - status builds line

  /// `SystemStatus.builds` (P6). Two filtered reads rather than one unfiltered `list(states: nil)`
  /// plus in-Swift counting: `image_builds` has no upper bound on terminal rows between purges, and
  /// this way `status` never pays to fetch/decode them just to throw them away.
  private static let runningBuildStates: Set<ImageBuildState> = [
    .resolving, .staging, .booting, .provisioning, .sealing,
  ]

  func buildsSummary() async -> BuildsSummary {
    async let queued = try? imageBuildRows.list(states: [.queued])
    async let running = try? imageBuildRows.list(states: Self.runningBuildStates)
    return BuildsSummary(running: await running?.count ?? 0, queued: await queued?.count ?? 0)
  }

  // MARK: - metrics.snapshot

  func metricsSnapshot(_ request: MetricsSnapshotRequest) async throws -> MetricsSnapshotResponse {
    let snapshot = await metrics.snapshot()
    return MetricsSnapshotResponse(
      collectedAt: snapshot.collectedAt,
      families: snapshot.families.map(Self.family),
      prometheus: request.format == .prometheus ? PrometheusEncoder.encode(snapshot) : nil)
  }

  /// Reads the whole registry, so it is also what the Prometheus endpoint renders.
  func metricsSnapshotValue() async -> MetricsSnapshot {
    await metrics.snapshot()
  }

  /// The gauges that belong to the daemon rather than to a scheduling pass (spec §17, §69).
  func refreshHostMetrics(_ pressure: DiskPressureReport) async {
    await metrics.setGauge(
      RunnerVMMetrics.diskPressureState,
      to: RunnerVMMetrics.diskPressureValue(pressure.state.rawValue))
    await metrics.setGauge(RunnerVMMetrics.hostFreeDiskBytes, to: Double(pressure.freeBytes))
    let sweep = await reconciler.state()
    await metrics.setCounter(RunnerVMMetrics.reconcileRunsTotal, to: Double(sweep.runCount))
    await metrics.setCounter(RunnerVMMetrics.reconcileErrorsTotal, to: Double(sweep.errorCount))
  }

  /// `Metrics` sits above `DaemonAPI` in the module graph, so the wire DTOs are a separate,
  /// field-for-field mirror rather than the same types.
  private static func family(_ family: MetricFamily) -> MetricFamilyDTO {
    MetricFamilyDTO(
      name: family.name, type: family.type.rawValue, help: family.help,
      samples: family.samples.map { sample in
        MetricSampleDTO(
          labels: sample.labels.map { MetricLabelDTO(name: $0.name, value: $0.value) },
          value: sample.value,
          histogram: sample.histogram.map {
            MetricHistogramDTO(
              buckets: $0.buckets, counts: $0.counts, sum: $0.sum, count: $0.count)
          })
      })
  }
}
