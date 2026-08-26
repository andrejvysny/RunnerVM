import ConfigLoader
import RunnerCore
import Testing

/// A minimal document (version + one scope + one linux profile) should decode with every absent
/// section resolving to the spec §65 defaults, not an error.
struct DefaultsTests {
  private static func loadMinimal() throws -> RunnerConfiguration {
    try ConfigLoader.load(yaml: Fixtures.minimalYAML)
  }

  @Test func hostDefaultsToTheStandardReserveAndAutoCapacity() throws {
    let config = try Self.loadMinimal()
    #expect(config.host == HostConfig())
    #expect(config.host.maxVMs == .auto)
  }

  @Test func profileDefaultsToLinuxEphemeralWithSpecSizing() throws {
    let profile = try #require(Self.loadMinimal().profile(named: "ubuntu-24"))
    #expect(profile.guestOS == .linux)
    #expect(profile.lifecycle == .ephemeral)
    #expect(profile.resources == ResourceSpec(
      cpuCount: 4, memoryBytes: ByteSize.gibibytes(8).bytes, diskBytes: ByteSize.gibibytes(80).bytes
    ))
  }

  @Test func profileDefaultsToNoWarmPoolAndSSHEnabled() throws {
    let profile = try #require(Self.loadMinimal().profile(named: "ubuntu-24"))
    #expect(profile.warmPool == .disabled)
    #expect(profile.warmPool.minIdle == 0)
    #expect(profile.limits.maxInstances == nil)
    #expect(profile.ssh.enabled)
    #expect(profile.reuse == nil)
    #expect(profile.effectiveTimeouts == .default)
  }

  @Test func remainingSectionsDefaultToTheirRunnerCoreDefaults() throws {
    let config = try Self.loadMinimal()
    #expect(config.security == SecurityConfig())
    #expect(config.metrics == MetricsConfig())
    #expect(config.diagnostics == DiagnosticsConfig())
    #expect(config.images == ImageCacheConfig())
    #expect(config.imageUpdates == ImageUpdatesConfig())
    #expect(config.github.auth == GitHubAuthConfig())
    #expect(config.github.demand == .scaleSet)
  }

  @Test func imageUpdatesIsReadFromTheRootSection() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    imageUpdates:
      recycleReusable: false
    """
    let config = try ConfigLoader.load(yaml: yaml)
    #expect(config.imageUpdates.recycleReusable == false)
  }

  @Test func reuseMaxRestartsIsReadFromTheProfileSection() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        lifecycle: reusable
        reuse:
          maxRestarts: 3
    """
    let profile = try #require(try ConfigLoader.load(yaml: yaml).profile(named: "ubuntu-24"))
    #expect(profile.reuse?.maxRestarts == 3)
  }

  @Test func reuseOmittingMaxRestartsDefaultsToOne() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        lifecycle: reusable
        reuse:
          maxJobs: 5
    """
    let profile = try #require(try ConfigLoader.load(yaml: yaml).profile(named: "ubuntu-24"))
    #expect(profile.reuse?.maxRestarts == 1)
  }

  @Test func demandModeIsReadFromTheGitHubSection() throws {
    let yaml = """
    version: 1
    github:
      demand: manual
      scopes:
        - {name: engineering, type: organization, owner: acme}
    """
    let config = try ConfigLoader.load(yaml: yaml)
    #expect(config.github.demand == .manual)
  }

  @Test func macosProfileWithoutAnOSFieldStillDefaultsToLinux() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: plain
        scope: engineering
        image: ghcr.io/acme/runners/plain:stable
    """
    let profile = try #require(try ConfigLoader.load(yaml: yaml).profile(named: "plain"))
    #expect(profile.guestOS == .linux)
  }
}
