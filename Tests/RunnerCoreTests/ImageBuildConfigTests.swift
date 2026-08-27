import Foundation
import RunnerCore
import Testing

@Suite struct ImageBuildConfigCodableTests {
  @Test func decodesLenientlyPerKey() throws {
    let json = """
      {"cpuCount": 8, "maxSteps": 100}
      """
    let config = try JSONDecoder().decode(ImageBuildConfig.self, from: Data(json.utf8))
    let d = ImageBuildConfig()
    #expect(config.cpuCount == 8)
    #expect(config.maxSteps == 100)
    #expect(config.memoryBytes == d.memoryBytes)
    #expect(config.diskBytes == d.diskBytes)
    #expect(config.timeout == d.timeout)
    #expect(config.stepTimeout == d.stepTimeout)
    #expect(config.maxConcurrent == d.maxConcurrent)
    #expect(config.cacheDir == nil)
    #expect(config.cache == BaseImageCachePolicy())
    #expect(config.guestAgentPath == nil)
    #expect(config.recipeFileName == d.recipeFileName)
    #expect(config.maxContextBytes == d.maxContextBytes)
    #expect(config.maxLogBytes == d.maxLogBytes)
  }

  @Test func emptyDocumentDecodesToAllDefaults() throws {
    let config = try JSONDecoder().decode(ImageBuildConfig.self, from: Data("{}".utf8))
    #expect(config == ImageBuildConfig())
  }

  @Test func defaultsMatchTheDesign() {
    let d = ImageBuildConfig()
    #expect(d.cpuCount == 4)
    #expect(d.memoryBytes == ByteSize.gibibytes(4).bytes)
    #expect(d.diskBytes == ByteSize.gibibytes(16).bytes)
    #expect(d.timeout == .minutes(60))
    #expect(d.stepTimeout == .minutes(30))
    #expect(d.maxConcurrent == 1)
    #expect(d.recipeFileName == "Runnerfile")
    #expect(d.maxContextBytes == ByteSize.gibibytes(1).bytes)
    #expect(d.maxLogBytes == ByteSize.mebibytes(64).bytes)
    #expect(d.maxSteps == 256)
  }

  @Test func roundTripsThroughJSON() throws {
    let config = ImageBuildConfig(
      cpuCount: 6, memoryBytes: ByteSize.gibibytes(8).bytes, diskBytes: ByteSize.gibibytes(32).bytes,
      timeout: .minutes(90), stepTimeout: .minutes(20), maxConcurrent: 2, cacheDir: "/tmp/cache",
      guestAgentPath: "/tmp/agent", recipeFileName: "Buildfile",
      maxContextBytes: ByteSize.gibibytes(2).bytes, maxLogBytes: ByteSize.mebibytes(128).bytes,
      maxSteps: 64
    )
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(ImageBuildConfig.self, from: data) == config)
  }
}

@Suite struct ImageBuildValidationTests {
  @Test func rejectsCPUCountBelowOne() {
    #expect(Fixtures.issues { $0.build.cpuCount = 0 }.contains(code: "BUILD_CPUS_INVALID"))
  }

  @Test func rejectsCPUCountAboveHostMaximum() {
    #expect(Fixtures.issues { $0.build.cpuCount = Fixtures.hostFacts.maximumAllowedCPUCount + 1 }
      .contains(code: "BUILD_CPUS_INVALID"))
  }

  @Test func rejectsMemoryBelowOneGiB() {
    #expect(Fixtures.issues { $0.build.memoryBytes = ByteSize.mebibytes(512).bytes }
      .contains(code: "BUILD_MEMORY_INVALID"))
  }

  @Test func rejectsDiskBelowEightGiB() {
    #expect(Fixtures.issues { $0.build.diskBytes = ByteSize.gibibytes(4).bytes }
      .contains(code: "BUILD_DISK_TOO_SMALL"))
  }

  @Test func rejectsNonPositiveTimeout() {
    #expect(Fixtures.issues { $0.build.timeout = .zero }.contains(code: "BUILD_TIMEOUT_INVALID"))
  }

  /// The guest agent silently clamps exec timeouts at 30 minutes, so a longer step timeout would
  /// never actually apply.
  @Test func rejectsStepTimeoutLongerThanThirtyMinutes() {
    #expect(Fixtures.issues { $0.build.stepTimeout = .minutes(45) }
      .contains(code: "BUILD_STEP_TIMEOUT_TOO_LONG"))
  }

  @Test func acceptsStepTimeoutOfExactlyThirtyMinutes() {
    #expect(!Fixtures.issues { $0.build.stepTimeout = .minutes(30) }
      .contains(code: "BUILD_STEP_TIMEOUT_TOO_LONG"))
  }

  @Test func rejectsMaxConcurrentOutOfRange() {
    #expect(Fixtures.issues { $0.build.maxConcurrent = -1 }.contains(code: "BUILD_MAX_CONCURRENT_INVALID"))
    #expect(Fixtures.issues { $0.build.maxConcurrent = 5 }.contains(code: "BUILD_MAX_CONCURRENT_INVALID"))
  }

  @Test func rejectsEmptyOrPathlikeRecipeFileName() {
    #expect(Fixtures.issues { $0.build.recipeFileName = "" }
      .contains(code: "BUILD_RECIPE_FILENAME_INVALID"))
    #expect(Fixtures.issues { $0.build.recipeFileName = "sub/Runnerfile" }
      .contains(code: "BUILD_RECIPE_FILENAME_INVALID"))
  }

  @Test func rejectsMaxStepsBelowOne() {
    #expect(Fixtures.issues { $0.build.maxSteps = 0 }.contains(code: "BUILD_MAX_STEPS_INVALID"))
  }

  @Test func defaultBuildConfigProducesNoIssues() {
    #expect(Fixtures.validConfiguration().validate(host: Fixtures.hostFacts)
      .filter { $0.path.hasPrefix("build.") }.isEmpty)
  }

  // MARK: - build.cache

  @Test func theBaseImageCachePolicyDecodesLenientlyPerKey() throws {
    let json = """
      {"cache": {"maxEntries": 3}}
      """
    let config = try JSONDecoder().decode(ImageBuildConfig.self, from: Data(json.utf8))
    #expect(config.cache.maxEntries == 3)
    #expect(config.cache.maxBytes == nil)
    #expect(config.cache.minimumHostFreeBytes == BaseImageCachePolicy().minimumHostFreeBytes)
  }

  @Test func theBaseImageCachePolicyDefaultsAreUnboundedButFloored() {
    let d = BaseImageCachePolicy()
    #expect(d.maxBytes == nil)
    #expect(d.maxEntries == nil)
    #expect(d.minimumHostFreeBytes == ByteSize.gibibytes(10).bytes)
  }

  /// "Set but useless" is an error; "absent" is how unbounded is spelled.
  @Test func aZeroBaseImageCacheCeilingIsRejectedWhileAbsenceIsNot() {
    #expect(!Fixtures.issues { _ in }.contains(code: "BUILD_CACHE_MAX_BYTES_INVALID"))
    let issues = Fixtures.issues {
      $0.build.cache = BaseImageCachePolicy(maxBytes: 0, maxEntries: 0)
    }
    #expect(issues.contains(code: "BUILD_CACHE_MAX_BYTES_INVALID"))
    #expect(issues.contains(code: "BUILD_CACHE_MAX_ENTRIES_INVALID"))
    #expect(issues.first(code: "BUILD_CACHE_MAX_ENTRIES_INVALID")?.path == "build.cache.maxEntries")
  }
}
