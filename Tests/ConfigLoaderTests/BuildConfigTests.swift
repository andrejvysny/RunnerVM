import ConfigLoader
import Foundation
import RunnerCore
import Testing

/// The `build:` section (Phase 4/5 image builder): defaults when absent, every field readable when
/// present, a typo rejected rather than silently ignored, and one validation rule wired through
/// end to end.
struct BuildConfigTests {
  private static func load(_ yaml: String) throws -> RunnerConfiguration {
    try ConfigLoader.load(yaml: yaml)
  }

  private static let scopeOnly = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    """

  @Test func absentSectionResolvesToTheRunnerCoreDefaults() throws {
    let config = try Self.load(Fixtures.minimalYAML)
    #expect(config.build == ImageBuildConfig())
    #expect(config.build.cpuCount == 4)
    #expect(config.build.recipeFileName == "Runnerfile")
  }

  @Test func everyFieldIsReadFromTheDocument() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      build:
        cpu: 6
        memory: 8GiB
        disk: 32GiB
        timeout: 90m
        stepTimeout: 20m
        maxConcurrent: 2
        cacheDir: /var/cache/runnervm-build
        guestAgentPath: /usr/local/bin/runnervm-guest-agent
        recipeFileName: Buildfile
        maxContextSize: 2GiB
        maxLogSize: 128MiB
        maxSteps: 64
      """)
    #expect(config.build.cpuCount == 6)
    #expect(config.build.memoryBytes == ByteSize.gibibytes(8).bytes)
    #expect(config.build.diskBytes == ByteSize.gibibytes(32).bytes)
    #expect(config.build.timeout == .minutes(90))
    #expect(config.build.stepTimeout == .minutes(20))
    #expect(config.build.maxConcurrent == 2)
    #expect(config.build.cacheDir == "/var/cache/runnervm-build")
    #expect(config.build.guestAgentPath == "/usr/local/bin/runnervm-guest-agent")
    #expect(config.build.recipeFileName == "Buildfile")
    #expect(config.build.maxContextBytes == ByteSize.gibibytes(2).bytes)
    #expect(config.build.maxLogBytes == ByteSize.mebibytes(128).bytes)
    #expect(config.build.maxSteps == 64)
  }

  @Test func aPartialSectionKeepsTheDefaultsForEverythingElse() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      build:
        maxConcurrent: 3
      """)
    #expect(config.build.maxConcurrent == 3)
    #expect(config.build.cpuCount == ImageBuildConfig().cpuCount)
    #expect(config.build.recipeFileName == ImageBuildConfig().recipeFileName)
  }

  @Test func anUnknownKeyIsRejectedRatherThanIgnored() throws {
    #expect(throws: (any Error).self) {
      _ = try Self.load("""
        \(Self.scopeOnly)
        build:
          cpuCount: 4
        """)
    }
  }

  /// The guest agent silently clamps exec timeouts at 30 minutes, so a longer step timeout is
  /// caught at validation, not silently ignored.
  @Test func stepTimeoutAboveThirtyMinutesFailsValidation() throws {
    let yaml = """
      \(Self.scopeOnly)
      build:
        stepTimeout: 45m
      """
    // Loading alone succeeds: the value is well-formed, just out of range.
    let config = try Self.load(yaml)
    #expect(config.build.stepTimeout == .minutes(45))

    let error = #expect(throws: ConfigLoadError.self) {
      try ConfigLoader.loadAndValidate(yaml: yaml, host: Fixtures.hostFacts)
    }
    let loadError = try #require(error)
    guard case let .validationFailed(issues) = loadError else {
      Issue.record("unexpected error \(loadError)")
      return
    }
    #expect(issues.contains(code: "BUILD_STEP_TIMEOUT_TOO_LONG"))
  }

  /// A document persisted by a build that predates this section must still load (spec §63/§91).
  @Test func aDocumentWithoutTheSectionStillDecodesThroughCodable() throws {
    let encoded = try JSONEncoder().encode(RunnerConfiguration())
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "build")
    let older = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RunnerConfiguration.self, from: older)
    #expect(decoded.build == ImageBuildConfig())
  }

  @Test func theSectionRoundTripsThroughCodable() throws {
    let original = RunnerConfiguration(
      build: ImageBuildConfig(cpuCount: 2, maxConcurrent: 4, recipeFileName: "Buildfile"))
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(RunnerConfiguration.self, from: data).build == original.build)
  }

  // MARK: - build.cache

  @Test func theBaseImageCacheSectionDefaultsWhenAbsent() throws {
    let config = try Self.load(Fixtures.minimalYAML)
    #expect(config.build.cache == BaseImageCachePolicy())
    #expect(config.build.cache.maxBytes == nil)
    #expect(config.build.cache.maxEntries == nil)
    #expect(config.build.cache.minimumHostFreeBytes == ByteSize.gibibytes(10).bytes)
  }

  @Test func theBaseImageCacheSectionRoundTripsThroughYAML() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      build:
        cache:
          maxBytes: 40GiB
          minimumHostFreeBytes: 25GiB
          maxEntries: 6
      """)
    #expect(config.build.cache.maxBytes == ByteSize.gibibytes(40).bytes)
    #expect(config.build.cache.minimumHostFreeBytes == ByteSize.gibibytes(25).bytes)
    #expect(config.build.cache.maxEntries == 6)
    // The rest of `build:` is untouched by the new subsection.
    #expect(config.build.cpuCount == ImageBuildConfig().cpuCount)
  }

  @Test func aBaseImageCacheTypoIsRejectedRatherThanIgnored() throws {
    #expect(throws: (any Error).self) {
      _ = try Self.load("""
        \(Self.scopeOnly)
        build:
          cache:
            maxSize: 40GiB
        """)
    }
  }

  @Test func aZeroBaseImageCacheCeilingFailsValidation() throws {
    let yaml = """
      \(Self.scopeOnly)
      build:
        cache:
          maxBytes: 0B
          maxEntries: 0
      """
    let error = #expect(throws: ConfigLoadError.self) {
      try ConfigLoader.loadAndValidate(yaml: yaml, host: Fixtures.hostFacts)
    }
    let loadError = try #require(error)
    guard case let .validationFailed(issues) = loadError else {
      Issue.record("unexpected error \(loadError)")
      return
    }
    #expect(issues.contains(code: "BUILD_CACHE_MAX_BYTES_INVALID"))
    #expect(issues.contains(code: "BUILD_CACHE_MAX_ENTRIES_INVALID"))
  }

  // MARK: - images.limits

  @Test func imagesLimitsDefaultsWhenAbsent() throws {
    let config = try Self.load(Fixtures.minimalYAML)
    #expect(config.images.limits == ImageLimitsConfig())
  }

  @Test func imagesLimitsIsReadFromTheDocument() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      images:
        limits:
          maxVirtualDiskSize: 256GiB
          maxLayers: 1024
      """)
    #expect(config.images.limits.maxVirtualDiskBytes == ByteSize.gibibytes(256).bytes)
    #expect(config.images.limits.maxLayers == 1_024)
  }

  @Test func imagesLimitsUnknownKeyIsRejected() throws {
    #expect(throws: (any Error).self) {
      _ = try Self.load("""
        \(Self.scopeOnly)
        images:
          limits:
            maxLayerCount: 10
        """)
    }
  }
}
