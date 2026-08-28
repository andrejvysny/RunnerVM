import Foundation

// MARK: - Host

extension HostConfig {
  func validate(facts: HostFacts) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if reserve.cpu < 0 {
      issues.append(.error("HOST_RESERVE_CPU_NEGATIVE", "host.reserve.cpu", "must not be negative"))
    } else if reserve.cpu >= facts.logicalCPUCount {
      issues.append(.error(
        "HOST_RESERVE_CPU_EXCEEDS_HOST", "host.reserve.cpu",
        "reserving \(reserve.cpu) of \(facts.logicalCPUCount) logical CPUs leaves no budget"
      ))
    }
    if reserve.memoryBytes >= facts.physicalMemoryBytes {
      issues.append(.error(
        "HOST_RESERVE_MEMORY_EXCEEDS_HOST", "host.reserve.memory",
        "reserving \(ByteSize(bytes: reserve.memoryBytes)) of "
          + "\(ByteSize(bytes: facts.physicalMemoryBytes)) leaves no budget"
      ))
    }
    issues += validateOvercommit()
    if case .count(let n) = maxVMs, n < 1 {
      issues.append(.error("HOST_MAX_VMS_INVALID", "host.maxVMs", "must be at least 1 or \"auto\""))
    }
    if limits.concurrentImagePulls < 1 {
      issues.append(.error(
        "HOST_CONCURRENT_IMAGE_PULLS_INVALID", "host.limits.concurrentImagePulls", "must be at least 1"
      ))
    }
    if limits.concurrentVMStarts < 1 {
      issues.append(.error(
        "HOST_CONCURRENT_VM_STARTS_INVALID", "host.limits.concurrentVMStarts", "must be at least 1"
      ))
    }
    return issues
  }

  private func validateOvercommit() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if !(overcommit.cpu >= 1.0) {
      issues.append(.error(
        "HOST_OVERCOMMIT_CPU_TOO_LOW", "host.overcommit.cpu", "must be at least 1.0"
      ))
    }
    if !(overcommit.memory >= 1.0) {
      issues.append(.error(
        "HOST_OVERCOMMIT_MEMORY_TOO_LOW", "host.overcommit.memory", "must be at least 1.0"
      ))
    } else if overcommit.memory > 1.0 {
      issues.append(.warning(
        "HOST_MEMORY_OVERCOMMIT_ENABLED", "host.overcommit.memory",
        "guests touch their whole memory balloon; overcommit can swap the host"
      ))
    }
    if !(overcommit.disk >= 1.0) {
      issues.append(.error(
        "HOST_OVERCOMMIT_DISK_TOO_LOW", "host.overcommit.disk", "must be at least 1.0"
      ))
    } else if overcommit.disk > 1.0 {
      issues.append(.warning(
        "HOST_DISK_OVERCOMMIT_ENABLED", "host.overcommit.disk",
        "admission reserves each guest's apparent disk size, but an instance disk is an APFS "
          + "clone that only grows as the job writes; above 1.0 a guest that does fill its disk "
          + "can exhaust host storage under the daemon and every other VM"
      ))
    }
    return issues
  }
}

// MARK: - GitHub

extension GitHubConfig {
  func validate() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if scopes.isEmpty {
      issues.append(.warning("GITHUB_NO_SCOPES", "github.scopes", "no GitHub scopes configured"))
    }
    if demand == .manual {
      issues.append(.warning(
        "GITHUB_DEMAND_MANUAL", "github.demand",
        "manual demand mode is for tests/debugging; production hosts should use scaleSet"
      ))
    }
    var seen = Set<String>()
    for (index, scope) in scopes.enumerated() {
      let path = "github.scopes[\(index)]"
      if scope.name.isEmpty {
        issues.append(.error("SCOPE_NAME_EMPTY", "\(path).name", "scope name must not be empty"))
      } else if !seen.insert(scope.name).inserted {
        issues.append(.error(
          "SCOPE_DUPLICATE_NAME", "\(path).name", "duplicate scope name '\(scope.name)'"
        ))
      }
      if scope.owner.isEmpty {
        issues.append(.error("SCOPE_OWNER_EMPTY", "\(path).owner", "owner must not be empty"))
      }
      switch scope.kind {
      case .repository where (scope.repository ?? "").isEmpty:
        issues.append(.error(
          "SCOPE_REPOSITORY_MISSING", "\(path).repository",
          "repository scopes require a repository name"
        ))
      case .organization where scope.repository != nil:
        issues.append(.warning(
          "SCOPE_REPOSITORY_UNUSED", "\(path).repository",
          "repository is ignored for organization scopes"
        ))
      default:
        break
      }
    }
    return issues
  }
}

// MARK: - Profiles

extension RunnerConfiguration {
  func validateProfiles(facts: HostFacts) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if profiles.isEmpty {
      issues.append(.warning("PROFILES_EMPTY", "profiles", "no runner profiles configured"))
    }
    var seen = Set<String>()
    let scopeNames = Set(github.scopes.map(\.name))
    for (index, profile) in profiles.enumerated() {
      let path = "profiles[\(index)]"
      if profile.name.isEmpty {
        issues.append(.error("PROFILE_NAME_EMPTY", "\(path).name", "profile name must not be empty"))
      } else if !Self.isValidProfileName(profile.name) {
        issues.append(.error(
          "PROFILE_NAME_INVALID", "\(path).name",
          "must match [a-z0-9][a-z0-9._-]* so it can be used in instance and runner names"
        ))
      } else if !seen.insert(profile.name).inserted {
        issues.append(.error(
          "PROFILE_DUPLICATE_NAME", "\(path).name", "duplicate profile name '\(profile.name)'"
        ))
      }
      if !scopeNames.contains(profile.scope) {
        issues.append(.error(
          "PROFILE_UNKNOWN_SCOPE", "\(path).scope", "unknown scope '\(profile.scope)'"
        ))
      }
      if !ImageReference.isValidProfileImage(profile.image) {
        issues.append(.error(
          "PROFILE_IMAGE_REFERENCE_INVALID", "\(path).image",
          "expected <registry>/<path>[:tag][@sha256:<64 hex>]"
        ))
      }
      if !HostConstants.supportedGuestOS.contains(profile.guestOS) {
        issues.append(.error(
          "GUEST_OS_UNSUPPORTED", "\(path).os",
          "guest OS \(profile.guestOS.rawValue) is not supported in this build; supported: linux, macos"
        ))
      }
      issues += profile.validateResources(facts: facts, path: path)
      issues += profile.validateWarmPool(path: path)
      issues += profile.validateLifecycle(path: path)
      issues += profile.validateHostedLabelShadowing(path: path)
      issues += profile.validateTimeouts(path: path)
    }
    return issues
  }

  static func isValidProfileName(_ name: String) -> Bool {
    guard let first = name.first, first.isNumber || (first.isLetter && first.isLowercase) else {
      return false
    }
    return name.allSatisfy {
      $0.isNumber || ($0.isLetter && $0.isLowercase) || $0 == "." || $0 == "_" || $0 == "-"
    }
  }

  /// Aggregate macOS rules against `HostConstants.macOSGuestLimit`: two concurrent macOS guests
  /// per host is RunnerVM's fixed default, matching Apple's standard macOS license allowance and
  /// the supported Virtualization.framework operating model -- not a framework error code.
  func validateMacOSAggregates() -> [ConfigurationIssue] {
    let macProfiles = profiles.filter { $0.guestOS == .macos }
    guard !macProfiles.isEmpty else { return [] }
    var issues: [ConfigurationIssue] = []
    let minIdleTotal = macProfiles.reduce(0) { $0 + max(0, $1.warmPool.minIdle) }
    if minIdleTotal > HostConstants.macOSGuestLimit {
      issues.append(.error(
        "MACOS_MIN_IDLE_EXCEEDS_GUEST_LIMIT", "profiles",
        "macOS warm pools request \(minIdleTotal) idle guests but the host allows "
          + "\(HostConstants.macOSGuestLimit)"
      ))
    }
    // Only a warning: the limit binds at runtime, and over-subscribing maxInstances across
    // profiles is a legitimate way to share the two slots.
    let maxInstancesTotal = macProfiles.reduce(0) { $0 + ($1.limits.maxInstances ?? 0) }
    if maxInstancesTotal > HostConstants.macOSGuestLimit {
      issues.append(.warning(
        "MACOS_MAX_INSTANCES_EXCEEDS_GUEST_LIMIT", "profiles",
        "macOS profiles allow \(maxInstancesTotal) instances but at most "
          + "\(HostConstants.macOSGuestLimit) can run at once"
      ))
    }
    return issues
  }
}

// MARK: - Remaining sections

extension SecurityConfig {
  func validate() -> [ConfigurationIssue] {
    guard allowPublicRepositories else { return [] }
    return [.warning(
      "SECURITY_PUBLIC_REPOSITORIES_ENABLED", "security.allowPublicRepositories",
      "public pull requests can execute untrusted code on this host"
    )]
  }
}

extension MetricsConfig {
  func validate() -> [ConfigurationIssue] {
    guard prometheus.enabled else { return [] }
    guard let separator = prometheus.listen.lastIndex(of: ":") else {
      return [.error("METRICS_LISTEN_INVALID", "metrics.prometheus.listen", "expected <host>:<port>")]
    }
    let host = prometheus.listen[..<separator]
    let port = Int(prometheus.listen[prometheus.listen.index(after: separator)...])
    guard !host.isEmpty, let port, (1...65_535).contains(port) else {
      return [.error("METRICS_LISTEN_INVALID", "metrics.prometheus.listen", "expected <host>:<port>")]
    }
    return []
  }
}

extension DiagnosticsConfig {
  func validate() -> [ConfigurationIssue] {
    guard failedInstanceRetention < .zero else { return [] }
    return [.error(
      "DIAGNOSTICS_RETENTION_NEGATIVE", "diagnostics.failedInstanceRetention",
      "must not be negative"
    )]
  }
}

extension ImageCacheConfig {
  func validate() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if let maxSizeBytes, maxSizeBytes < ByteSize.gibibytes(1).bytes {
      issues.append(.error(
        "IMAGE_CACHE_MAX_SIZE_TOO_SMALL", "images.maxSize",
        "must be at least 1GiB; a smaller cache cannot hold a single image"
      ))
    }
    if keepRecentlyUsed < .zero {
      issues.append(.error(
        "IMAGE_CACHE_KEEP_RECENTLY_USED_NEGATIVE", "images.keepRecentlyUsed", "must not be negative"
      ))
    }
    return issues
  }
}

extension ImageBuildConfig {
  /// A step timeout longer than this never actually applies: the guest agent silently clamps every
  /// exec it runs at 30 minutes, so a longer configured value would just be quietly ineffective.
  static let maxStepTimeout = DurationValue.minutes(30)
  static let minMemoryBytes = ByteSize.gibibytes(1).bytes
  static let minDiskBytes = ByteSize.gibibytes(8).bytes
  static let maxAllowedConcurrent = 4

  func validate(facts: HostFacts) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if cpuCount < 1 || cpuCount > facts.maximumAllowedCPUCount {
      issues.append(.error(
        "BUILD_CPUS_INVALID", "build.cpuCount",
        "must be between 1 and \(facts.maximumAllowedCPUCount)"
      ))
    }
    if memoryBytes < Self.minMemoryBytes {
      issues.append(.error(
        "BUILD_MEMORY_INVALID", "build.memoryBytes",
        "must be at least \(ByteSize(bytes: Self.minMemoryBytes))"
      ))
    }
    if diskBytes < Self.minDiskBytes {
      issues.append(.error(
        "BUILD_DISK_TOO_SMALL", "build.diskBytes",
        "must be at least \(ByteSize(bytes: Self.minDiskBytes))"
      ))
    }
    issues += validateTimeouts()
    if maxConcurrent < 0 || maxConcurrent > Self.maxAllowedConcurrent {
      issues.append(.error(
        "BUILD_MAX_CONCURRENT_INVALID", "build.maxConcurrent",
        "must be between 0 and \(Self.maxAllowedConcurrent)"
      ))
    }
    if recipeFileName.isEmpty || recipeFileName.contains("/") {
      issues.append(.error(
        "BUILD_RECIPE_FILENAME_INVALID", "build.recipeFileName",
        "must be a bare filename, not empty and containing no '/'"
      ))
    }
    if maxSteps < 1 {
      issues.append(.error("BUILD_MAX_STEPS_INVALID", "build.maxSteps", "must be at least 1"))
    }
    issues += cache.validate()
    return issues
  }

  private func validateTimeouts() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if !timeout.isPositive {
      issues.append(.error("BUILD_TIMEOUT_INVALID", "build.timeout", "must be positive"))
    }
    if stepTimeout > Self.maxStepTimeout {
      issues.append(.error(
        "BUILD_STEP_TIMEOUT_TOO_LONG", "build.stepTimeout",
        "must not exceed \(Self.maxStepTimeout); the guest agent clamps exec timeouts there"
      ))
    }
    return issues
  }
}

extension BaseImageCachePolicy {
  /// A zero ceiling would evict every base the moment it landed and turn every build into a
  /// re-download, so "set but useless" is rejected rather than silently accepted; `nil` (absent)
  /// is the way to say "unbounded".
  func validate() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if let maxBytes, maxBytes == 0 {
      issues.append(.error(
        "BUILD_CACHE_MAX_BYTES_INVALID", "build.cache.maxBytes",
        "must be greater than 0; omit the key for an unbounded cache"
      ))
    }
    if let maxEntries, maxEntries < 1 {
      issues.append(.error(
        "BUILD_CACHE_MAX_ENTRIES_INVALID", "build.cache.maxEntries",
        "must be at least 1; omit the key for an unbounded cache"
      ))
    }
    return issues
  }
}

extension LoggingConfig {
  /// A file too small to hold one burst of startup logs rotates continuously, and a `maxFiles`
  /// of zero silently discards the archive an operator went looking for.
  func validate() -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if file.enabled, file.maxSizeBytes < ByteSize.mebibytes(1).bytes {
      issues.append(.error(
        "LOGGING_FILE_MAX_SIZE_TOO_SMALL", "logging.file.maxSize", "must be at least 1MiB"
      ))
    }
    if file.enabled, !(1...100).contains(file.maxFiles) {
      issues.append(.error(
        "LOGGING_FILE_MAX_FILES_INVALID", "logging.file.maxFiles", "must be between 1 and 100"
      ))
    }
    if retention.instanceLogs < .zero {
      issues.append(.error(
        "LOGGING_RETENTION_NEGATIVE", "logging.retention.instanceLogs", "must not be negative"
      ))
    } else if !retention.instanceLogs.isPositive {
      issues.append(.warning(
        "LOGGING_RETENTION_DISABLED", "logging.retention.instanceLogs",
        "0 keeps every per-instance log directory forever"
      ))
    }
    if collectRunnerDiagnostics, !diagnosticsTimeout.isPositive {
      issues.append(.error(
        "LOGGING_DIAGNOSTICS_TIMEOUT_INVALID", "logging.diagnosticsTimeout",
        "must be positive while collectRunnerDiagnostics is on"
      ))
    }
    return issues
  }
}
