import Foundation
import RunnerCore

enum Fixtures {
  /// An M2-class Mac: 10 logical CPUs, 32 GiB, VZ bounds around it.
  static let hostFacts = HostFacts(
    logicalCPUCount: 10,
    physicalMemoryBytes: ByteSize.gibibytes(32).bytes,
    minimumAllowedCPUCount: 1,
    maximumAllowedCPUCount: 10,
    minimumAllowedMemoryBytes: ByteSize.mebibytes(128).bytes,
    maximumAllowedMemoryBytes: ByteSize.gibibytes(32).bytes
  )

  static let organizationScope = GitHubScopeConfig(
    name: "engineering", kind: .organization, owner: "acme", runnerGroup: "Default"
  )

  static let repositoryScope = GitHubScopeConfig(
    name: "project-a", kind: .repository, owner: "acme", repository: "project-a"
  )

  static let linuxProfile = RunnerProfileConfig(
    name: "ubuntu-24",
    scope: "engineering",
    image: "ghcr.io/acme/runners/ubuntu-24:stable",
    guestOS: .linux,
    limits: ProfileLimits(maxInstances: 4)
  )

  static let macosProfile = RunnerProfileConfig(
    name: "macos-15-xcode-16",
    scope: "engineering",
    image: "ghcr.io/acme/runners/macos-15-xcode-16:stable",
    guestOS: .macos,
    limits: ProfileLimits(maxInstances: 2)
  )

  /// Baseline that must produce zero issues; every rule test mutates one field of this.
  static func validConfiguration() -> RunnerConfiguration {
    RunnerConfiguration(
      host: HostConfig(),
      github: GitHubConfig(scopes: [organizationScope]),
      profiles: [linuxProfile]
    )
  }

  static func configuration(
    mutating transform: (inout RunnerConfiguration) -> Void
  ) -> RunnerConfiguration {
    var config = validConfiguration()
    transform(&config)
    return config
  }

  static func issues(
    mutating transform: (inout RunnerConfiguration) -> Void
  ) -> [ConfigurationIssue] {
    configuration(mutating: transform).validate(host: hostFacts)
  }
}

extension RunnerProfileConfig {
  /// Copy-with-one-field-changed, so each rule test states exactly the field it exercises.
  func with(_ transform: (inout RunnerProfileConfig) -> Void) -> RunnerProfileConfig {
    var copy = self
    transform(&copy)
    return copy
  }
}
