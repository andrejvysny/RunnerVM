import Foundation

extension RunnerProfileConfig {
  /// One MiB alignment: Virtualization.framework rejects memory sizes that are not a multiple of
  /// the host page-aligned MiB granularity.
  static let memoryAlignmentBytes = ByteSize.mebibytes(1).bytes
  /// A guest smaller than this cannot hold the runner plus a workspace.
  static let minimumDiskBytes = ByteSize.gibibytes(1).bytes
  /// Spec §72: past this many restarts, a dying worker points at the disk or image, not bad luck.
  static let maxAllowedRestarts = 5

  func validateResources(facts: HostFacts, path: String) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    let cpuPath = "\(path).resources.cpu"
    if resources.cpuCount < facts.minimumAllowedCPUCount {
      issues.append(.error(
        "PROFILE_CPU_BELOW_HOST_MINIMUM", cpuPath,
        "\(resources.cpuCount) vCPU is below the host minimum of \(facts.minimumAllowedCPUCount)"
      ))
    }
    if resources.cpuCount > facts.maximumAllowedCPUCount {
      issues.append(.error(
        "PROFILE_CPU_ABOVE_HOST_MAXIMUM", cpuPath,
        "\(resources.cpuCount) vCPU exceeds the host maximum of \(facts.maximumAllowedCPUCount)"
      ))
    }
    // Tart observed frequent guest freezes below 4 vCPU on macOS guests.
    if guestOS == .macos, resources.cpuCount < HostConstants.macOSMinimumCPUCount {
      issues.append(.error(
        "PROFILE_CPU_BELOW_MACOS_MINIMUM", cpuPath,
        "macOS guests need at least \(HostConstants.macOSMinimumCPUCount) vCPU"
      ))
    }
    issues += validateMemory(facts: facts, path: path)
    if resources.diskBytes < Self.minimumDiskBytes {
      issues.append(.error(
        "PROFILE_DISK_TOO_SMALL", "\(path).resources.disk",
        "\(ByteSize(bytes: resources.diskBytes)) is below the minimum of "
          + "\(ByteSize(bytes: Self.minimumDiskBytes))"
      ))
    }
    return issues
  }

  private func validateMemory(facts: HostFacts, path: String) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    let memoryPath = "\(path).resources.memory"
    if resources.memoryBytes < facts.minimumAllowedMemoryBytes {
      issues.append(.error(
        "PROFILE_MEMORY_BELOW_HOST_MINIMUM", memoryPath,
        "\(ByteSize(bytes: resources.memoryBytes)) is below the host minimum of "
          + "\(ByteSize(bytes: facts.minimumAllowedMemoryBytes))"
      ))
    }
    if resources.memoryBytes > facts.maximumAllowedMemoryBytes {
      issues.append(.error(
        "PROFILE_MEMORY_ABOVE_HOST_MAXIMUM", memoryPath,
        "\(ByteSize(bytes: resources.memoryBytes)) exceeds the host maximum of "
          + "\(ByteSize(bytes: facts.maximumAllowedMemoryBytes))"
      ))
    }
    if resources.memoryBytes % Self.memoryAlignmentBytes != 0 {
      issues.append(.error(
        "PROFILE_MEMORY_NOT_MIB_ALIGNED", memoryPath, "must be a whole number of MiB"
      ))
    }
    return issues
  }

  func validateWarmPool(path: String) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if warmPool.minIdle < 0 {
      issues.append(.error(
        "PROFILE_MIN_IDLE_NEGATIVE", "\(path).warmPool.minIdle", "must not be negative"
      ))
    }
    if warmPool.maxIdle < 0 {
      issues.append(.error(
        "PROFILE_MAX_IDLE_NEGATIVE", "\(path).warmPool.maxIdle", "must not be negative"
      ))
    }
    if warmPool.minIdle > warmPool.maxIdle {
      issues.append(.error(
        "PROFILE_MIN_IDLE_EXCEEDS_MAX_IDLE", "\(path).warmPool.minIdle",
        "minIdle \(warmPool.minIdle) exceeds maxIdle \(warmPool.maxIdle)"
      ))
    }
    if let maxInstances = limits.maxInstances {
      if maxInstances < 1 {
        issues.append(.error(
          "PROFILE_MAX_INSTANCES_INVALID", "\(path).limits.maxInstances", "must be at least 1"
        ))
      } else if warmPool.maxIdle > maxInstances {
        issues.append(.error(
          "PROFILE_MAX_IDLE_EXCEEDS_MAX_INSTANCES", "\(path).warmPool.maxIdle",
          "maxIdle \(warmPool.maxIdle) exceeds maxInstances \(maxInstances)"
        ))
      }
    }
    // A warm pool with no TTL would keep a dead-idle VM forever.
    if warmPool.maxIdle > 0, !warmPool.idleTTL.isPositive {
      issues.append(.error(
        "PROFILE_IDLE_TTL_NOT_POSITIVE", "\(path).warmPool.idleTTL",
        "must be positive when maxIdle is greater than 0"
      ))
    }
    return issues
  }

  func validateLifecycle(path: String) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    guard let reuse else {
      return issues
    }
    guard lifecycle == .reusable else {
      return [.warning(
        "PROFILE_REUSE_IGNORED", "\(path).reuse",
        "reuse policy is ignored for ephemeral profiles"
      )]
    }
    if reuse.maxJobs < 1 {
      issues.append(.error(
        "PROFILE_REUSE_MAX_JOBS_INVALID", "\(path).reuse.maxJobs", "must be at least 1"
      ))
    }
    if !reuse.maxAge.isPositive {
      issues.append(.error(
        "PROFILE_REUSE_MAX_AGE_NOT_POSITIVE", "\(path).reuse.maxAge", "must be positive"
      ))
    }
    if reuse.maxRestarts < 0 || reuse.maxRestarts > Self.maxAllowedRestarts {
      issues.append(.error(
        "PROFILE_REUSE_MAX_RESTARTS_INVALID", "\(path).reuse.maxRestarts",
        "must be between 0 and \(Self.maxAllowedRestarts)"
      ))
    }
    return issues
  }

  func validateTimeouts(path: String) -> [ConfigurationIssue] {
    guard let timeouts else { return [] }
    return timeouts.all.filter { !$0.value.isPositive }.map {
      .error("PROFILE_TIMEOUT_NOT_POSITIVE", "\(path).timeouts.\($0.name)", "must be positive")
    }
  }
}
