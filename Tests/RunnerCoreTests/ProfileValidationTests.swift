import Foundation
import RunnerCore
import Testing

@Suite struct ProfileValidationTests {
  private static func issues(
    _ transform: (inout RunnerProfileConfig) -> Void
  ) -> [ConfigurationIssue] {
    Fixtures.issues { $0.profiles = [Fixtures.linuxProfile.with(transform)] }
  }

  private static func macIssues(
    _ transform: (inout RunnerProfileConfig) -> Void
  ) -> [ConfigurationIssue] {
    Fixtures.issues { $0.profiles = [Fixtures.macosProfile.with(transform)] }
  }

  @Test func rejectsDuplicateProfileNames() {
    let issues = Fixtures.issues { $0.profiles = [Fixtures.linuxProfile, Fixtures.linuxProfile] }
    #expect(issues.contains(code: "PROFILE_DUPLICATE_NAME"))
  }

  @Test func rejectsUnknownScopeReference() {
    #expect(Self.issues { $0.scope = "nope" }.contains(code: "PROFILE_UNKNOWN_SCOPE"))
  }

  @Test func rejectsEmptyOrMalformedProfileNames() {
    #expect(Self.issues { $0.name = "" }.contains(code: "PROFILE_NAME_EMPTY"))
    #expect(Self.issues { $0.name = "Ubuntu 24" }.contains(code: "PROFILE_NAME_INVALID"))
    #expect(Self.issues { $0.name = "-leading" }.contains(code: "PROFILE_NAME_INVALID"))
    #expect(Self.issues { $0.name = "ok.name_1-2" }.isEmpty)
  }

  @Test(arguments: [
    "acme/ubuntu-24:stable",
    "ghcr.io/acme/ubuntu-24:BAD TAG",
    "ghcr.io/acme/UPPER:stable",
    "ghcr.io/acme/ubuntu@sha256:short",
    "ghcr.io/",
    "",
  ])
  func rejectsInvalidImageReferences(reference: String) {
    #expect(Self.issues { $0.image = reference }.contains(code: "PROFILE_IMAGE_REFERENCE_INVALID"))
  }

  @Test(arguments: [
    "ghcr.io/acme/runners/ubuntu-24:stable",
    "ghcr.io/acme/ubuntu-24",
    "localhost:5000/acme/ubuntu-24:dev",
    "ubuntu-24",
    "ubuntu-24:m2",
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "ghcr.io/acme/ubuntu-24@sha256:"
      + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  ])
  func acceptsValidImageReferences(reference: String) {
    #expect(!Self.issues { $0.image = reference }.contains(code: "PROFILE_IMAGE_REFERENCE_INVALID"))
  }

  // MARK: - Resources

  @Test func rejectsCPUOutsideHostBounds() {
    #expect(Self.issues { $0.resources.cpuCount = 0 }
      .contains(code: "PROFILE_CPU_BELOW_HOST_MINIMUM"))
    #expect(Self.issues { $0.resources.cpuCount = -4 }
      .contains(code: "PROFILE_CPU_BELOW_HOST_MINIMUM"))
    #expect(Self.issues { $0.resources.cpuCount = 64 }
      .contains(code: "PROFILE_CPU_ABOVE_HOST_MAXIMUM"))
  }

  @Test func rejectsMacOSProfilesBelowTheFourVCPUFloor() {
    let issues = Self.macIssues { $0.resources.cpuCount = HostConstants.macOSMinimumCPUCount - 1 }
    #expect(issues.contains(code: "PROFILE_CPU_BELOW_MACOS_MINIMUM"))
    // The same value is fine for a Linux guest.
    #expect(!Self.issues { $0.resources.cpuCount = HostConstants.macOSMinimumCPUCount - 1 }
      .contains(code: "PROFILE_CPU_BELOW_MACOS_MINIMUM"))
  }

  @Test func rejectsMemoryOutsideHostBounds() {
    #expect(Self.issues { $0.resources.memoryBytes = ByteSize.mebibytes(64).bytes }
      .contains(code: "PROFILE_MEMORY_BELOW_HOST_MINIMUM"))
    #expect(Self.issues { $0.resources.memoryBytes = ByteSize.gibibytes(64).bytes }
      .contains(code: "PROFILE_MEMORY_ABOVE_HOST_MAXIMUM"))
  }

  @Test func rejectsMemoryThatIsNotAWholeNumberOfMiB() {
    let issues = Self.issues { $0.resources.memoryBytes = ByteSize.gibibytes(8).bytes + 1 }
    #expect(issues.contains(code: "PROFILE_MEMORY_NOT_MIB_ALIGNED"))
    #expect(!Self.issues { $0.resources.memoryBytes = ByteSize.mebibytes(6144).bytes }
      .contains(code: "PROFILE_MEMORY_NOT_MIB_ALIGNED"))
  }

  @Test func rejectsDiskBelowOneGiB() {
    #expect(Self.issues { $0.resources.diskBytes = ByteSize.mebibytes(512).bytes }
      .contains(code: "PROFILE_DISK_TOO_SMALL"))
    #expect(Self.issues { $0.resources.diskBytes = 0 }.contains(code: "PROFILE_DISK_TOO_SMALL"))
    #expect(!Self.issues { $0.resources.diskBytes = ByteSize.gibibytes(1).bytes }
      .contains(code: "PROFILE_DISK_TOO_SMALL"))
  }

  @Test func defaultSizingMatchesTheSpec() {
    #expect(ResourceSpec.defaults(for: .linux)
      == ResourceSpec(
        cpuCount: 4,
        memoryBytes: ByteSize.gibibytes(8).bytes,
        diskBytes: ByteSize.gibibytes(80).bytes
      ))
    #expect(ResourceSpec.defaults(for: .macos)
      == ResourceSpec(
        cpuCount: 6,
        memoryBytes: ByteSize.gibibytes(12).bytes,
        diskBytes: ByteSize.gibibytes(120).bytes
      ))
  }

  // MARK: - Warm pool and limits

  @Test func rejectsMinIdleAboveMaxIdle() {
    let issues = Self.issues { $0.warmPool = WarmPoolPolicy(minIdle: 3, maxIdle: 1) }
    #expect(issues.contains(code: "PROFILE_MIN_IDLE_EXCEEDS_MAX_IDLE"))
  }

  @Test func rejectsMaxIdleAboveMaxInstances() {
    let issues = Self.issues {
      $0.warmPool = WarmPoolPolicy(minIdle: 1, maxIdle: 5)
      $0.limits = ProfileLimits(maxInstances: 4)
    }
    #expect(issues.contains(code: "PROFILE_MAX_IDLE_EXCEEDS_MAX_INSTANCES"))
  }

  @Test func maxIdleIsUnboundedWhenMaxInstancesIsAbsent() {
    let issues = Self.issues {
      $0.warmPool = WarmPoolPolicy(minIdle: 1, maxIdle: 9)
      $0.limits = ProfileLimits(maxInstances: nil)
    }
    #expect(issues.isEmpty)
  }

  @Test func rejectsNegativeWarmPoolCounts() {
    #expect(Self.issues { $0.warmPool = WarmPoolPolicy(minIdle: -1, maxIdle: 0) }
      .contains(code: "PROFILE_MIN_IDLE_NEGATIVE"))
    #expect(Self.issues { $0.warmPool = WarmPoolPolicy(minIdle: -2, maxIdle: -1) }
      .contains(code: "PROFILE_MAX_IDLE_NEGATIVE"))
  }

  @Test func rejectsNonPositiveMaxInstances() {
    #expect(Self.issues { $0.limits = ProfileLimits(maxInstances: 0) }
      .contains(code: "PROFILE_MAX_INSTANCES_INVALID"))
  }

  @Test func rejectsAWarmPoolWithoutATTL() {
    let issues = Self.issues {
      $0.warmPool = WarmPoolPolicy(minIdle: 1, maxIdle: 2, idleTTL: .zero)
    }
    #expect(issues.contains(code: "PROFILE_IDLE_TTL_NOT_POSITIVE"))
    // With no warm pool at all the TTL is irrelevant.
    #expect(!Self.issues { $0.warmPool = WarmPoolPolicy(minIdle: 0, maxIdle: 0, idleTTL: .zero) }
      .contains(code: "PROFILE_IDLE_TTL_NOT_POSITIVE"))
  }

  // MARK: - Lifecycle and timeouts

  @Test func warnsWhenAReusePolicyIsSetOnAnEphemeralProfile() throws {
    let issues = Self.issues {
      $0.lifecycle = .ephemeral
      $0.reuse = ReusePolicy()
    }
    #expect(try #require(issues.first(code: "PROFILE_REUSE_IGNORED")).severity == .warning)
    #expect(!issues.hasErrors)
  }

  @Test func rejectsDegenerateReuseBounds() {
    #expect(Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxJobs: 0)
    }.contains(code: "PROFILE_REUSE_MAX_JOBS_INVALID"))
    #expect(Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxAge: .zero)
    }.contains(code: "PROFILE_REUSE_MAX_AGE_NOT_POSITIVE"))
  }

  @Test func rejectsMaxRestartsOutsideZeroToFive() {
    #expect(Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxRestarts: -1)
    }.contains(code: "PROFILE_REUSE_MAX_RESTARTS_INVALID"))
    #expect(Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxRestarts: 6)
    }.contains(code: "PROFILE_REUSE_MAX_RESTARTS_INVALID"))
    #expect(!Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxRestarts: 0)
    }.contains(code: "PROFILE_REUSE_MAX_RESTARTS_INVALID"))
    #expect(!Self.issues {
      $0.lifecycle = .reusable
      $0.reuse = ReusePolicy(maxRestarts: 5)
    }.contains(code: "PROFILE_REUSE_MAX_RESTARTS_INVALID"))
  }

  @Test func effectiveReuseAppliesOnlyToReusableProfiles() {
    #expect(Fixtures.linuxProfile.effectiveReuse == nil)
    #expect(Fixtures.linuxProfile.with { $0.lifecycle = .reusable }.effectiveReuse == .default)
  }

  @Test func rejectsNonPositiveTimeouts() {
    let issues = Self.issues { $0.timeouts = TimeoutPolicy(vmBoot: .zero, agentReady: .seconds(-1)) }
    let paths = issues.filter { $0.code == "PROFILE_TIMEOUT_NOT_POSITIVE" }.map(\.path)
    #expect(paths.contains("profiles[0].timeouts.vmBoot"))
    #expect(paths.contains("profiles[0].timeouts.agentReady"))
    #expect(paths.count == 2)
  }

  @Test func timeoutDefaultsMatchTheSpec() {
    let timeouts = TimeoutPolicy.default
    #expect(timeouts.vmBoot == .minutes(3))
    #expect(timeouts.agentReady == .minutes(2))
    #expect(timeouts.runnerOnline == .minutes(2))
    #expect(timeouts.gracefulShutdown == .seconds(30))
    #expect(Fixtures.linuxProfile.effectiveTimeouts == .default)
    #expect(timeouts.all.count == 9)
    #expect(timeouts.all.allSatisfy { $0.value.isPositive })
  }

  // MARK: - macOS aggregates

  @Test func rejectsMacOSWarmPoolsBeyondTheTwoGuestLimit() throws {
    let issues = Fixtures.issues {
      $0.profiles = [
        Fixtures.macosProfile.with {
          $0.warmPool = WarmPoolPolicy(minIdle: 2, maxIdle: 2)
          $0.limits = ProfileLimits(maxInstances: 2)
        },
        Fixtures.macosProfile.with {
          $0.name = "macos-15-xcode-15"
          $0.warmPool = WarmPoolPolicy(minIdle: 1, maxIdle: 1)
          $0.limits = ProfileLimits(maxInstances: 1)
        },
      ]
    }
    let issue = try #require(issues.first(code: "MACOS_MIN_IDLE_EXCEEDS_GUEST_LIMIT"))
    #expect(issue.severity == .error)
  }

  @Test func exactlyTwoMacOSIdleGuestsIsAllowed() {
    let issues = Fixtures.issues {
      $0.profiles = [Fixtures.macosProfile.with {
        $0.warmPool = WarmPoolPolicy(minIdle: 2, maxIdle: 2)
      }]
    }
    #expect(!issues.hasErrors)
  }

  @Test func warnsWhenMacOSMaxInstancesOversubscribeTheTwoGuestLimit() throws {
    let issues = Fixtures.issues {
      $0.profiles = [
        Fixtures.macosProfile.with { $0.limits = ProfileLimits(maxInstances: 2) },
        Fixtures.macosProfile.with {
          $0.name = "macos-15-xcode-15"
          $0.limits = ProfileLimits(maxInstances: 2)
        },
      ]
    }
    let issue = try #require(issues.first(code: "MACOS_MAX_INSTANCES_EXCEEDS_GUEST_LIMIT"))
    #expect(issue.severity == .warning)
    #expect(!issues.hasErrors)
  }

  @Test func linuxProfilesAreNotSubjectToTheMacOSGuestLimit() {
    let issues = Fixtures.issues {
      $0.profiles = [Fixtures.linuxProfile.with {
        $0.warmPool = WarmPoolPolicy(minIdle: 4, maxIdle: 4)
        $0.limits = ProfileLimits(maxInstances: 8)
      }]
    }
    #expect(issues.isEmpty)
  }
}

@Suite struct RemainingSectionValidationTests {
  @Test func warnsWhenPublicRepositoriesAreAllowed() throws {
    let issues = Fixtures.issues { $0.security.allowPublicRepositories = true }
    #expect(try #require(issues.first(code: "SECURITY_PUBLIC_REPOSITORIES_ENABLED")).severity
      == .warning)
  }

  @Test func validatesTheMetricsListenAddressOnlyWhenEnabled() {
    #expect(Fixtures.issues { $0.metrics.prometheus.listen = "nonsense" }.isEmpty)
    #expect(Fixtures.issues {
      $0.metrics.prometheus.enabled = true
      $0.metrics.prometheus.listen = "nonsense"
    }.contains(code: "METRICS_LISTEN_INVALID"))
    #expect(Fixtures.issues {
      $0.metrics.prometheus.enabled = true
      $0.metrics.prometheus.listen = "127.0.0.1:99999"
    }.contains(code: "METRICS_LISTEN_INVALID"))
    #expect(Fixtures.issues { $0.metrics.prometheus.enabled = true }.isEmpty)
  }

  @Test func rejectsNegativeDiagnosticsRetention() {
    #expect(Fixtures.issues { $0.diagnostics.failedInstanceRetention = .seconds(-1) }
      .contains(code: "DIAGNOSTICS_RETENTION_NEGATIVE"))
    #expect(Fixtures.issues { $0.diagnostics.failedInstanceRetention = .zero }.isEmpty)
  }

  @Test func rejectsAnImageCacheTooSmallForOneImage() {
    #expect(Fixtures.issues { $0.images.maxSizeBytes = ByteSize.mebibytes(200).bytes }
      .contains(code: "IMAGE_CACHE_MAX_SIZE_TOO_SMALL"))
    #expect(Fixtures.issues { $0.images.maxSizeBytes = ByteSize.gibibytes(500).bytes }.isEmpty)
    #expect(Fixtures.issues { $0.images.keepRecentlyUsed = .seconds(-1) }
      .contains(code: "IMAGE_CACHE_KEEP_RECENTLY_USED_NEGATIVE"))
  }

  @Test func everyIssueCodeIsUpperSnakeCase() {
    let config = Fixtures.configuration {
      $0.version = 9
      $0.host.reserve.cpu = -1
      $0.host.overcommit.memory = 0.5
      $0.profiles = [Fixtures.linuxProfile.with { $0.image = "bad" }]
      $0.security.allowPublicRepositories = true
    }
    let issues = config.validate(host: Fixtures.hostFacts)
    #expect(!issues.isEmpty)
    for issue in issues {
      #expect(issue.code.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }, "\(issue.code)")
      #expect(!issue.path.isEmpty)
    }
  }

  @Test func codesAreUniquePerRule() {
    let issues = Fixtures.issues { $0.version = 3 }
    #expect(Set(issues.map(\.code)).count == issues.count)
  }
}
