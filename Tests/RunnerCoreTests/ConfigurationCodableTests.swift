import Foundation
import RunnerCore
import Testing

@Suite struct ConfigurationCodableTests {
  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func roundTrip(_ config: RunnerConfiguration) throws -> RunnerConfiguration {
    let data = try encoder().encode(config)
    return try JSONDecoder().decode(RunnerConfiguration.self, from: data)
  }

  @Test func fullConfigurationRoundTrips() throws {
    let config = RunnerConfiguration(
      host: HostConfig(
        reserve: HostConfig.Reserve(
          cpu: 4,
          memoryBytes: ByteSize.gibibytes(8).bytes,
          diskBytes: ByteSize.gibibytes(100).bytes
        ),
        overcommit: HostConfig.Overcommit(cpu: 1.5, memory: 1.0),
        maxVMs: .count(6),
        limits: HostConfig.Limits(concurrentImagePulls: 3, concurrentVMStarts: 1)
      ),
      github: GitHubConfig(
        auth: GitHubAuthConfig(provider: .app, source: .file),
        scopes: [Fixtures.organizationScope, Fixtures.repositoryScope],
        demand: .manual
      ),
      profiles: [
        Fixtures.linuxProfile.with {
          $0.warmPool = WarmPoolPolicy(minIdle: 1, maxIdle: 2, idleTTL: .minutes(20))
          $0.timeouts = TimeoutPolicy()
        },
        Fixtures.macosProfile.with {
          $0.lifecycle = .reusable
          $0.reuse = ReusePolicy(maxJobs: 5, maxAge: .hours(4), recycleOnFailure: true)
          $0.ssh = SSHPolicy(enabled: false)
        },
      ],
      security: SecurityConfig(allowPublicRepositories: true),
      metrics: MetricsConfig(prometheus: .init(enabled: true, listen: "127.0.0.1:9095")),
      diagnostics: DiagnosticsConfig(failedInstanceRetention: .hours(2)),
      images: ImageCacheConfig(maxSizeBytes: ByteSize.gibibytes(500).bytes, keepRecentlyUsed: .days(7))
    )
    #expect(try Self.roundTrip(config) == config)
  }

  @Test func defaultConfigurationRoundTrips() throws {
    let config = Fixtures.validConfiguration()
    #expect(try Self.roundTrip(config) == config)
  }

  @Test func durationsEncodeAsHumanStrings() throws {
    let json = String(decoding: try Self.encoder().encode(TimeoutPolicy.default), as: UTF8.self)
    #expect(json.contains("\"vmBoot\":\"3m\""))
    #expect(json.contains("\"gracefulShutdown\":\"30s\""))
    #expect(json.contains("\"jobMaxRuntime\":\"6h\""))
  }

  @Test func maxVMsEncodesAsAutoOrInteger() throws {
    #expect(String(decoding: try Self.encoder().encode(HostConfig.MaxVMs.auto), as: UTF8.self)
      == "\"auto\"")
    #expect(String(decoding: try Self.encoder().encode(HostConfig.MaxVMs.count(4)), as: UTF8.self)
      == "4")
    #expect(try JSONDecoder().decode(HostConfig.MaxVMs.self, from: Data("\"auto\"".utf8)) == .auto)
    #expect(try JSONDecoder().decode(HostConfig.MaxVMs.self, from: Data("4".utf8)) == .count(4))
  }

  @Test func maxVMsRejectsOtherTokens() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(HostConfig.MaxVMs.self, from: Data("\"lots\"".utf8))
    }
  }

  @Test func minimalDocumentDecodesWithDefaults() throws {
    let json = """
      {"version": 1, "github": {"auth": {"provider": "pat", "source": "keychain"}, "scopes": []}}
      """
    let config = try JSONDecoder().decode(RunnerConfiguration.self, from: Data(json.utf8))
    #expect(config.host == HostConfig())
    #expect(config.profiles.isEmpty)
    #expect(config.security == SecurityConfig())
    #expect(config.metrics == MetricsConfig())
    #expect(config.diagnostics == DiagnosticsConfig())
    #expect(config.images == ImageCacheConfig())
    // `demand` is absent from this document; a build predating the field must still decode it.
    #expect(config.github.demand == .scaleSet)
  }

  @Test func demandDecodesFromAnExplicitValue() throws {
    let json = """
      {"auth": {"provider": "pat", "source": "keychain"}, "scopes": [], "demand": "manual"}
      """
    let config = try JSONDecoder().decode(GitHubConfig.self, from: Data(json.utf8))
    #expect(config.demand == .manual)
  }

  @Test func demandRoundTripsThroughRunnerConfiguration() throws {
    let config = Fixtures.configuration { $0.github.demand = .manual }
    #expect(try Self.roundTrip(config).github.demand == .manual)
  }

  @Test func profileOmittingOptionalSectionsDecodesWithDefaults() throws {
    let json = """
      {"name": "ubuntu-24", "scope": "engineering",
       "image": "ghcr.io/acme/runners/ubuntu-24:stable", "guestOS": "linux"}
      """
    let profile = try JSONDecoder().decode(RunnerProfileConfig.self, from: Data(json.utf8))
    #expect(profile.lifecycle == .ephemeral)
    #expect(profile.resources == .defaults(for: .linux))
    #expect(profile.warmPool == .disabled)
    #expect(profile.limits.maxInstances == nil)
    #expect(profile.ssh.enabled)
    #expect(profile.reuse == nil)
    #expect(profile.effectiveTimeouts == .default)
  }

  @Test func codingKeysAreCamelCase() throws {
    let json = String(decoding: try Self.encoder().encode(Fixtures.validConfiguration()), as: UTF8.self)
    for key in ["\"guestOS\"", "\"maxVMs\"", "\"warmPool\"", "\"maxInstances\"", "\"allowPublicRepositories\""] {
      #expect(json.contains(key), "\(key)")
    }
    #expect(!json.contains("guest_os"))
  }

  @Test func scopeKindUsesTheSpecSpelling() throws {
    let json = String(decoding: try Self.encoder().encode(Fixtures.repositoryScope), as: UTF8.self)
    #expect(json.contains("\"kind\":\"repository\""))
    #expect(GitHubScopeKind.allCases.map(\.rawValue) == ["organization", "repository"])
  }

  @Test func lifecycleAndGuestOSRawValuesMatchTheDatabaseCheckConstraints() {
    #expect(InstanceLifecycle.allCases.map(\.rawValue) == ["ephemeral", "reusable"])
    #expect(GuestOS.linux.rawValue == "linux")
    #expect(GuestOS.macos.rawValue == "macos")
  }

  @Test func imageUpdatesDefaultsToRecyclingReusableInstances() throws {
    #expect(Fixtures.validConfiguration().imageUpdates == ImageUpdatesConfig())
    #expect(ImageUpdatesConfig().recycleReusable)
  }

  @Test func imageUpdatesRoundTripsThroughRunnerConfiguration() throws {
    let config = Fixtures.configuration { $0.imageUpdates = ImageUpdatesConfig(recycleReusable: false) }
    #expect(try Self.roundTrip(config).imageUpdates.recycleReusable == false)
  }

  @Test func imageUpdatesIsAbsentInAnOlderDocumentStillDecodes() throws {
    let json = """
      {"version": 1, "github": {"auth": {"provider": "pat", "source": "keychain"}, "scopes": []}}
      """
    let config = try JSONDecoder().decode(RunnerConfiguration.self, from: Data(json.utf8))
    #expect(config.imageUpdates == ImageUpdatesConfig())
  }

  @Test func reusePolicyMaxRestartsDefaultsToOneAndRoundTrips() throws {
    #expect(ReusePolicy.default.maxRestarts == 1)
    let policy = ReusePolicy(maxRestarts: 3)
    let data = try Self.encoder().encode(policy)
    #expect(try JSONDecoder().decode(ReusePolicy.self, from: data).maxRestarts == 3)
  }

  @Test func reusePolicyMissingMaxRestartsDecodesToTheDefault() throws {
    let json = """
      {"maxJobs": 10, "maxAge": "4h", "recycleOnFailure": true}
      """
    let policy = try JSONDecoder().decode(ReusePolicy.self, from: Data(json.utf8))
    #expect(policy.maxRestarts == 1)
  }

  @Test func imageCacheMaxSizeIsOptional() throws {
    let config = Fixtures.configuration { $0.images = ImageCacheConfig(maxSizeBytes: nil) }
    let decoded = try Self.roundTrip(config)
    #expect(decoded.images.maxSizeBytes == nil)
  }

  @Test func profileHelpersExposeResolvedValues() {
    #expect(Fixtures.validConfiguration().profile(named: "ubuntu-24") != nil)
    #expect(Fixtures.validConfiguration().scope(named: "engineering") != nil)
    #expect(Fixtures.validConfiguration().profile(named: "missing") == nil)
    #expect(Fixtures.macosProfile.shortName == "macos15xcode")
  }
}
