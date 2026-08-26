import Foundation
import RunnerCore
import Testing

@Suite struct ValidationBaselineTests {
  @Test func validConfigurationProducesNoIssuesAtAll() {
    #expect(Fixtures.validConfiguration().validate(host: Fixtures.hostFacts).isEmpty)
  }

  @Test func validConfigurationPassesTheThrowingWrapper() throws {
    #expect(try Fixtures.validConfiguration().validated(host: Fixtures.hostFacts).isEmpty)
  }

  @Test func throwingWrapperAggregatesOnlyErrors() throws {
    let config = Fixtures.configuration {
      $0.version = 2
      $0.security.allowPublicRepositories = true
    }
    let error = #expect(throws: ConfigurationError.self) {
      try config.validated(host: Fixtures.hostFacts)
    }
    let unwrapped = try #require(error)
    guard case .validationFailed(let issues) = unwrapped else {
      Issue.record("unexpected error \(unwrapped)")
      return
    }
    #expect(issues.map(\.code) == ["CONFIG_UNSUPPORTED_VERSION"])
    #expect(unwrapped.code == "CONFIG_VALIDATION_FAILED")
  }

  @Test func macOSProfileIsRejectedAsUnsupportedGuestOS() throws {
    let issues = Fixtures.issues { $0.profiles = [Fixtures.macosProfile] }
    let issue = try #require(issues.first(code: "GUEST_OS_UNSUPPORTED"))
    #expect(issue.severity == .error)
    #expect(issue.path == "profiles[0].os")
  }

  @Test func issuesCarryASeverityCodePathAndMessage() throws {
    let issue = try #require(Fixtures.issues { $0.version = 7 }.first)
    #expect(issue.severity == .error)
    #expect(issue.code == "CONFIG_UNSUPPORTED_VERSION")
    #expect(issue.path == "version")
    #expect(!issue.message.isEmpty)
    #expect(issue.description.contains("CONFIG_UNSUPPORTED_VERSION"))
  }
}

@Suite struct HostValidationTests {
  @Test func rejectsUnsupportedVersion() {
    #expect(Fixtures.issues { $0.version = 2 }.contains(code: "CONFIG_UNSUPPORTED_VERSION"))
    #expect(Fixtures.issues { $0.version = 0 }.contains(code: "CONFIG_UNSUPPORTED_VERSION"))
  }

  @Test func rejectsNegativeCPUReserve() {
    #expect(Fixtures.issues { $0.host.reserve.cpu = -1 }.contains(code: "HOST_RESERVE_CPU_NEGATIVE"))
  }

  @Test func rejectsCPUReserveThatConsumesTheHost() {
    #expect(Fixtures.issues { $0.host.reserve.cpu = 10 }
      .contains(code: "HOST_RESERVE_CPU_EXCEEDS_HOST"))
  }

  @Test func rejectsMemoryReserveThatConsumesTheHost() {
    #expect(Fixtures.issues { $0.host.reserve.memoryBytes = ByteSize.gibibytes(32).bytes }
      .contains(code: "HOST_RESERVE_MEMORY_EXCEEDS_HOST"))
  }

  @Test func rejectsOvercommitBelowOne() {
    #expect(Fixtures.issues { $0.host.overcommit.cpu = 0.5 }
      .contains(code: "HOST_OVERCOMMIT_CPU_TOO_LOW"))
    #expect(Fixtures.issues { $0.host.overcommit.memory = 0.9 }
      .contains(code: "HOST_OVERCOMMIT_MEMORY_TOO_LOW"))
  }

  @Test func warnsAboutMemoryOvercommitAboveOne() throws {
    let issues = Fixtures.issues { $0.host.overcommit.memory = 1.5 }
    let issue = try #require(issues.first(code: "HOST_MEMORY_OVERCOMMIT_ENABLED"))
    #expect(issue.severity == .warning)
    #expect(!issues.hasErrors)
  }

  @Test func cpuOvercommitAboveOneIsAllowedSilently() {
    #expect(Fixtures.issues { $0.host.overcommit.cpu = 1.5 }.isEmpty)
  }

  @Test func rejectsNonPositiveMaxVMs() {
    #expect(Fixtures.issues { $0.host.maxVMs = .count(0) }.contains(code: "HOST_MAX_VMS_INVALID"))
    #expect(Fixtures.issues { $0.host.maxVMs = .count(3) }.isEmpty)
  }

  @Test func rejectsNonPositiveStartupConcurrency() {
    #expect(Fixtures.issues { $0.host.limits.concurrentImagePulls = 0 }
      .contains(code: "HOST_CONCURRENT_IMAGE_PULLS_INVALID"))
    #expect(Fixtures.issues { $0.host.limits.concurrentVMStarts = -2 }
      .contains(code: "HOST_CONCURRENT_VM_STARTS_INVALID"))
  }
}

@Suite struct ScopeValidationTests {
  @Test func rejectsDuplicateScopeNames() {
    let issues = Fixtures.issues {
      $0.github.scopes = [Fixtures.organizationScope, Fixtures.organizationScope]
    }
    #expect(issues.contains(code: "SCOPE_DUPLICATE_NAME"))
  }

  @Test func rejectsRepositoryScopeWithoutRepository() {
    let issues = Fixtures.issues {
      $0.github.scopes = [GitHubScopeConfig(name: "engineering", kind: .repository, owner: "acme")]
    }
    #expect(issues.contains(code: "SCOPE_REPOSITORY_MISSING"))
  }

  @Test func acceptsAFullyFormedRepositoryScope() {
    let issues = Fixtures.issues {
      $0.github.scopes = [Fixtures.repositoryScope]
      $0.profiles = [Fixtures.linuxProfile.with { $0.scope = "project-a" }]
    }
    #expect(issues.isEmpty)
  }

  @Test func rejectsEmptyScopeNameAndOwner() {
    let issues = Fixtures.issues {
      $0.github.scopes = [GitHubScopeConfig(name: "", kind: .organization, owner: "")]
    }
    #expect(issues.contains(code: "SCOPE_NAME_EMPTY"))
    #expect(issues.contains(code: "SCOPE_OWNER_EMPTY"))
  }

  @Test func warnsWhenAnOrganizationScopeCarriesARepository() throws {
    let issues = Fixtures.issues {
      $0.github.scopes = [GitHubScopeConfig(
        name: "engineering", kind: .organization, owner: "acme", repository: "ignored"
      )]
    }
    #expect(try #require(issues.first(code: "SCOPE_REPOSITORY_UNUSED")).severity == .warning)
  }

  @Test func warnsWhenNoScopesAreConfigured() throws {
    let issues = Fixtures.issues {
      $0.github.scopes = []
      $0.profiles = []
    }
    #expect(try #require(issues.first(code: "GITHUB_NO_SCOPES")).severity == .warning)
    #expect(try #require(issues.first(code: "PROFILES_EMPTY")).severity == .warning)
    #expect(!issues.hasErrors)
  }

  @Test func warnsWhenDemandModeIsManual() throws {
    let issues = Fixtures.issues { $0.github.demand = .manual }
    #expect(try #require(issues.first(code: "GITHUB_DEMAND_MANUAL")).severity == .warning)
    #expect(!issues.hasErrors)
  }

  @Test func scaleSetDemandModeProducesNoWarning() {
    #expect(!Fixtures.issues { $0.github.demand = .scaleSet }.contains(code: "GITHUB_DEMAND_MANUAL"))
  }

  @Test func scopeSlugFollowsTheAPIShape() {
    #expect(Fixtures.organizationScope.slug == "acme")
    #expect(Fixtures.repositoryScope.slug == "acme/project-a")
  }
}
