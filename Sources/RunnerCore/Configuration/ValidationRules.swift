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
          "guest OS \(profile.guestOS.rawValue) is not supported in this build; supported: linux/arm64"
        ))
      }
      issues += profile.validateResources(facts: facts, path: path)
      issues += profile.validateWarmPool(path: path)
      issues += profile.validateLifecycle(path: path)
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

  /// Aggregate macOS rules: Virtualization.framework refuses a third concurrent macOS guest.
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
