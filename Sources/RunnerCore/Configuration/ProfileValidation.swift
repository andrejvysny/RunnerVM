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
    if lifecycle == .reusable {
      issues.append(contentsOf: validateMacOSIsEphemeral(path: path))
      issues.append(contentsOf: validateReusableIsolation(path: path))
    }
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

  /// A profile name is also the scale set's `runs-on` label. GitHub-hosted labels win that match:
  /// a job with `runs-on: macos-26` runs on GitHub's own macOS 26 runner and never reaches this
  /// host (seen live), so the shadowing names are flagged. Only the shapes GitHub actually uses
  /// (`macos-<major>`, `ubuntu-<major>.<minor>`, `windows-<year>`, `*-latest`, plus GitHub's size/arch
  /// suffixes) -- `ubuntu-24` and `macos-15-xcode-16` are fine.
  func validateHostedLabelShadowing(path: String) -> [ConfigurationIssue] {
    guard Self.shadowsHostedLabel(name) else { return [] }
    return [.warning(
      "PROFILE_NAME_SHADOWS_HOSTED_LABEL", "\(path).name",
      "'\(name)' matches a GitHub-hosted runner label; jobs with runs-on: \(name) run on GitHub's "
        + "hosted runners instead of this host. Prefix the name, e.g. rvm-\(name)"
    )]
  }

  static func shadowsHostedLabel(_ name: String) -> Bool {
    // GitHub's only suffixes are size/architecture variants; `macos-15-xcode-16` is a fine name.
    let suffix = #"(-(large|xlarge|intel|arm|arm64))?$"#
    let patterns = [
      #"^(ubuntu|macos|windows)-latest"# + suffix,
      #"^macos-[0-9]+"# + suffix,
      #"^ubuntu-[0-9]+\.[0-9]+"# + suffix,
      #"^windows-[0-9]{4}"# + suffix,
    ]
    return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
  }

  /// The between-jobs cleanup was written for a Linux guest and has no macOS equivalent yet, so a
  /// reusable macOS profile is refused outright rather than acknowledged like the Linux one.
  private func validateMacOSIsEphemeral(path: String) -> [ConfigurationIssue] {
    guard guestOS == .macos else { return [] }
    return [.error(
      "PROFILE_MACOS_REUSABLE_UNSUPPORTED", "\(path).lifecycle",
      "macOS guests are ephemeral-only in this release: Keychain, DerivedData, simulator and "
        + "Apple tooling state cannot be reset safely between jobs"
    )]
  }

  /// A reusable VM is not an isolation boundary between jobs: cleanup resets HOME, `_work` and
  /// temp space, but anything a job wrote elsewhere (via `sudo`, docker, system paths) survives
  /// into the next job. Ephemeral is the production default; reusable is refused unless the
  /// operator states that every job on the profile trusts the previous one.
  private func validateReusableIsolation(path: String) -> [ConfigurationIssue] {
    guard effectiveReuse?.acknowledgeSharedHost == true else {
      return [.error(
        "PROFILE_REUSABLE_UNACKNOWLEDGED", "\(path).reuse.acknowledgeSharedHost",
        "lifecycle: reusable shares one guest between consecutive jobs; set "
          + "reuse.acknowledgeSharedHost: true to confirm every job on this profile is trusted "
          + "with the previous job's host, or use lifecycle: ephemeral"
      )]
    }
    return [.warning(
      "PROFILE_REUSABLE_SINGLE_TENANT", "\(path).lifecycle",
      "reusable VMs are single-tenant: jobs on this profile share a guest and are not isolated "
        + "from each other beyond the HOME/_work/temp reset between jobs"
    )]
  }

  func validateTimeouts(path: String) -> [ConfigurationIssue] {
    guard let timeouts else { return [] }
    var issues = timeouts.all.filter { !$0.value.isPositive }.map {
      ConfigurationIssue.error(
        "PROFILE_TIMEOUT_NOT_POSITIVE", "\(path).timeouts.\($0.name)", "must be positive")
    }
    // `clone` is parsed but never applied: `clonefile(2)` is synchronous and uninterruptible, and
    // faking a deadline around it would only ever report a timeout after the work was done.
    if timeouts.clone != TimeoutPolicy.default.clone {
      issues.append(.warning(
        "PROFILE_TIMEOUT_CLONE_IGNORED", "\(path).timeouts.clone",
        "not enforced: instance disks are created with clonefile(2), which has no cancellation "
          + "point; remove the setting"))
    }
    return issues
  }
}
