import Foundation

/// The metric catalogue: spec §40 (host-side worker figures), §41 (lifecycle timings) plus the
/// capacity, demand and session-outcome series `runnerctl metrics` reports.
///
/// Names are declared here rather than at each call site so a family exists — with help and type —
/// from the first scrape, before anything has been observed into it.
public enum RunnerVMMetrics {
  // Lifecycle timings (spec §41).
  public static let imagePullSeconds = "runnervm_image_pull_seconds"
  public static let instanceCloneSeconds = "runnervm_instance_clone_seconds"
  public static let workerStartSeconds = "runnervm_worker_start_seconds"
  public static let vmBootToRunningSeconds = "runnervm_vm_boot_to_running_seconds"
  public static let vmRunningToAgentReadySeconds = "runnervm_vm_running_to_agent_ready_seconds"
  public static let jitGenerationSeconds = "runnervm_jit_generation_seconds"
  public static let jitDeliveryToRunnerOnlineSeconds =
    "runnervm_jit_delivery_to_runner_online_seconds"
  public static let jobDurationSeconds = "runnervm_job_duration_seconds"
  public static let cleanupSeconds = "runnervm_cleanup_seconds"
  public static let instanceDeleteSeconds = "runnervm_instance_delete_seconds"

  // Capacity and demand.
  public static let instances = "runnervm_instances"
  public static let capacityAdvertised = "runnervm_capacity_advertised"
  public static let demandAssignedJobs = "runnervm_demand_assigned_jobs"
  public static let reservedCPU = "runnervm_reserved_cpu"
  public static let reservedMemoryBytes = "runnervm_reserved_memory_bytes"
  public static let hostFreeDiskBytes = "runnervm_host_free_disk_bytes"
  public static let diskPressureState = "runnervm_disk_pressure_state"
  public static let instanceCloneMethod = "runnervm_instance_clone_method"

  // Image runner-software freshness (spec §53).
  public static let imageRunnerVersionHealth = "runnervm_image_runner_version_health"
  public static let runnerLatestReleaseAgeSeconds = "runnervm_runner_latest_release_age_seconds"

  // Host-observed worker figures (spec §40). Never guest memory — see the help text.
  public static let workerRSSBytes = "runnervm_worker_rss_bytes"
  public static let workerCPUPercent = "runnervm_worker_cpu_percent"

  // Outcomes.
  public static let sessionsTotal = "runnervm_sessions_total"
  public static let instanceFailuresTotal = "runnervm_instance_failures_total"
  public static let reconcileRunsTotal = "runnervm_reconcile_runs_total"
  public static let reconcileErrorsTotal = "runnervm_reconcile_errors_total"
  public static let githubRequestsTotal = "runnervm_github_requests_total"

  // Logging durability (spec §42).
  public static let logLinesDroppedTotal = "runnervm_log_lines_dropped_total"
  public static let instanceLogDirsSweptTotal = "runnervm_instance_log_dirs_swept_total"

  // Label names. The exposed label values are profile names, instance ids, state names and fixed
  // enumerations only: nothing an operator typed into a workflow reaches a metric label.
  public static let profileLabel = "profile"
  public static let instanceLabel = "instance"
  public static let stateLabel = "state"
  public static let resultLabel = "result"
  public static let codeLabel = "code"
  public static let methodLabel = "method"
  public static let classLabel = "class"
  public static let digestLabel = "digest"
  public static let healthLabel = "health"

  /// `runnervm_disk_pressure_state` is numeric so it can be alerted on: 0 ok, 1 warning,
  /// 2 critical (spec §17).
  public static func diskPressureValue(_ state: String) -> Double {
    switch state {
    case "warning": 1
    case "critical": 2
    default: 0
    }
  }

  public static let definitions: [MetricDefinition] =
    timings + capacity + images + workers + outcomes

  private static let timings: [MetricDefinition] = [
    MetricDefinition(
      name: imagePullSeconds, kind: .histogram,
      help: "Seconds spent pulling an image into the local store."),
    MetricDefinition(
      name: instanceCloneSeconds, kind: .histogram,
      help: "Seconds spent cloning an image into a new instance directory."),
    MetricDefinition(
      name: workerStartSeconds, kind: .histogram,
      help: "Seconds from spawning vmworker to its fenced session being usable."),
    MetricDefinition(
      name: vmBootToRunningSeconds, kind: .histogram,
      help: "Seconds from starting the VM to vmworker reporting it running."),
    MetricDefinition(
      name: vmRunningToAgentReadySeconds, kind: .histogram,
      help: "Seconds from the VM running to the guest agent completing its handshake."),
    MetricDefinition(
      name: jitGenerationSeconds, kind: .histogram,
      help: "Seconds from opening a runner session to GitHub issuing its JIT config."),
    MetricDefinition(
      name: jitDeliveryToRunnerOnlineSeconds, kind: .histogram,
      help: "Seconds from delivering the JIT config to the runner reporting online."),
    MetricDefinition(
      name: jobDurationSeconds, kind: .histogram, help: "Seconds a GitHub job ran on a VM."),
    MetricDefinition(
      name: cleanupSeconds, kind: .histogram,
      help: "Seconds spent taking a VM down or cleaning it for reuse after a session."),
    MetricDefinition(
      name: instanceDeleteSeconds, kind: .histogram,
      help: "Seconds spent deleting an instance and its directory."),
  ]

  private static let capacity: [MetricDefinition] = [
    MetricDefinition(name: instances, kind: .gauge, help: "Instances by profile and state."),
    MetricDefinition(
      name: capacityAdvertised, kind: .gauge,
      help: "Capacity advertised to GitHub for this profile; 0 while the host is draining."),
    MetricDefinition(
      name: demandAssignedJobs, kind: .gauge,
      help: "Jobs GitHub reports as assigned to this profile."),
    MetricDefinition(
      name: reservedCPU, kind: .gauge, help: "vCPUs reserved by capacity-consuming instances."),
    MetricDefinition(
      name: reservedMemoryBytes, kind: .gauge,
      help: "Guest memory reserved by capacity-consuming instances, in bytes."),
    MetricDefinition(
      name: hostFreeDiskBytes, kind: .gauge, help: "Free bytes on the RunnerVM state volume."),
    MetricDefinition(
      name: diskPressureState, kind: .gauge, help: "Disk pressure: 0 ok, 1 warning, 2 critical."),
    MetricDefinition(
      name: instanceCloneMethod, kind: .gauge,
      help: "Instance directories materialized by clone method since daemon start."),
  ]

  private static let images: [MetricDefinition] = [
    MetricDefinition(
      name: imageRunnerVersionHealth, kind: .gauge,
      help: "1 for the runner-software freshness bucket each local image currently falls in: "
        + "healthy, stale, tooOld or unknown."),
    MetricDefinition(
      name: runnerLatestReleaseAgeSeconds, kind: .gauge,
      help: "Seconds since GitHub published the newest actions/runner release; absent until it "
        + "has been read."),
  ]

  private static let workers: [MetricDefinition] = [
    MetricDefinition(
      name: workerRSSBytes, kind: .gauge,
      help: "Resident memory of the vmworker host process. Not guest memory usage."),
    MetricDefinition(
      name: workerCPUPercent, kind: .gauge,
      help: "CPU percent of the vmworker host process since the previous sample."),
  ]

  private static let outcomes: [MetricDefinition] = [
    MetricDefinition(
      name: sessionsTotal, kind: .counter,
      help: "Runner sessions that reached a terminal state, by profile and terminal state."),
    MetricDefinition(
      name: instanceFailuresTotal, kind: .counter,
      help: "Instances that failed to come up, by profile and failure code."),
    MetricDefinition(
      name: reconcileRunsTotal, kind: .counter, help: "Reconcile sweeps run since daemon start."),
    MetricDefinition(
      name: reconcileErrorsTotal, kind: .counter, help: "Reconcile sweeps that reported an error."),
    MetricDefinition(
      name: githubRequestsTotal, kind: .counter, help: "GitHub API requests by outcome class."),
    MetricDefinition(
      name: logLinesDroppedTotal, kind: .counter,
      help: "Log lines a rotating file sink could not write. Non-zero means logs are being lost."),
    MetricDefinition(
      name: instanceLogDirsSweptTotal, kind: .counter,
      help: "Per-instance log directories deleted by the logging.retention.instanceLogs sweep."),
  ]
}
