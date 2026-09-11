import Foundation
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// The daemon's slow loop (spec §17, §57, §74). Split out of `DaemonServiceImpl.swift` to keep
/// that file under its line budget; every member below runs actor-isolated on `DaemonServiceImpl`
/// exactly as if it were declared there.
extension DaemonServiceImpl {
  /// Refresh disk pressure, drop abandoned image import staging left by a crashed
  /// `image.import`, re-probe GitHub, and sweep expired per-instance logs. Runs far less often
  /// than the reconcile loop and never deletes a published image -- that stays behind the explicit
  /// `image.prune` gate (spec §110 "do not implement aggressive GC before correct reference
  /// accounting exists").
  func runMaintenance() async {
    let pressure = await diskPressure.refresh(floorBytes: reserveDiskFloor())
    await refreshHostMetrics(pressure)
    _ = try? await images.sweepStaging(olderThan: .seconds(3_600))
    await gateway.probe()
    await scopeHealth.refresh()
    await runnerVersions.refreshIfDue()
    await refreshRunnerVersionMetrics()
    await runners.retryPendingRemovals()
    await sweepInstanceLogs()
    await reprobeHostIfDegraded()
  }

  /// A probe that was killed at its deadline says something about one run of `vmworker probe`, not
  /// about the host -- yet its verdict used to pin `virtualizationSupported: false` into
  /// `system.status` and into config validation for the daemon's whole life, so a host that had
  /// merely been busy at startup (a wedged Virtualization query, a helper waiting on a lock) was
  /// reported as incapable until someone restarted runnerd (D11).
  ///
  /// Only a probe that was *killed at its deadline* is re-run. Every other degraded reason -- no
  /// `vmworker` on this host, an unsigned or unreadable one, JSON this build cannot decode -- is a
  /// static fact that the next tick would reach again, so re-probing it would produce five minutes
  /// of identical warnings and nothing else. `hostProbeTimeouts` is the operator-visible count;
  /// `HostSummary` has no field for it, so it rides the log lines below rather than the wire.
  private func reprobeHostIfDegraded() async {
    guard probe.probeTimedOut, let executable = vmworkerExecutable,
          FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
    else { return }
    let refreshed = await HostProbe.run(executable: executable, logger: logger)
    if refreshed.probeTimedOut { hostProbeTimeouts += 1 }
    probe = refreshed
    guard refreshed.probeSucceeded else {
      logger.warning(
        "host probe still degraded after a maintenance re-probe",
        metadata: [
          "probe_timeouts": .stringConvertible(hostProbeTimeouts),
          "reason": .string(refreshed.failureReason ?? "unknown"),
        ])
      return
    }
    logger.info(
      "host probe recovered on the maintenance loop",
      metadata: ["probe_timeouts": .stringConvertible(hostProbeTimeouts)])
  }

  /// Spec §74. On the slow loop rather than the reconcile tick: it walks a directory tree, and
  /// nothing about log retention needs ten-second resolution.
  private func sweepInstanceLogs() async {
    let config = appliedConfiguration()?.logging ?? LoggingConfig()
    let live = Set(
      ((try? await instanceRows.list(profile: nil, states: nil)) ?? [])
        .filter { $0.state != .deleted }
        .map(\.id))
    let swept = InstanceLogRetention(paths: paths, logger: logger)
      .sweep(olderThan: config.retention.instanceLogs.duration, keeping: live)
    if !swept.isEmpty {
      await metrics.increment(RunnerVMMetrics.instanceLogDirsSweptTotal, by: Double(swept.count))
    }
    // Published here rather than at the sink: the sinks are built in `runnerd`'s `main`, long
    // before any metric registry exists.
    await metrics.setCounter(
      RunnerVMMetrics.logLinesDroppedTotal, to: Double(RotatingFileSink.totalDroppedLines))
  }
}
