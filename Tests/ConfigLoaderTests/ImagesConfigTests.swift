import ConfigLoader
import Foundation
import RunnerCore
import Testing

/// `images.updates` / `images.managed`: the configuration surface phases D6/D7 will read. Nothing
/// acts on these fields yet, so everything provable about them today is decoding, defaulting and
/// validation.
struct ImagesConfigTests {
  private static let fullBlock = """
  version: 1

  github:
    scopes:
      - name: engineering
        type: organization
        owner: acme

  images:
    prefetch: true
    updates:
      enabled: true
      interval: 6h
      jitter: 30m
      keepPrevious: 2
      smokeTest: false
    managed:
      - name: macos-tahoe-base
        kind: macos-tart
        source: ghcr.io/cirruslabs/macos-tahoe-base:latest
        autoUpdate: false
        resources:
          cpu: 6
          memory: 12GiB

  profiles:
    - name: ubuntu-24
      scope: engineering
      image: ghcr.io/acme/runners/ubuntu-24:stable
  """

  /// `Fixtures.minimalYAML` with an `images:` block spliced in.
  private static func withImages(_ block: String) -> String {
    Fixtures.minimalYAML + "\n\nimages:\n" + block
  }

  // MARK: - Schema and mapping

  @Test func schemaAcceptsTheWholeBlockAndMapsEveryField() throws {
    let images = try ConfigLoader.load(yaml: Self.fullBlock).images
    #expect(images.prefetch)
    #expect(images.updates == ImageUpdatePolicyConfig(
      enabled: true, interval: .hours(6), jitter: .minutes(30), keepPrevious: 2, smokeTest: false
    ))
    #expect(images.managed == [ManagedImageSourceConfig(
      name: "macos-tahoe-base", kind: .macosTart,
      source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", autoUpdate: false,
      resources: ManagedImageSourceConfig.Resources(
        cpuCount: 6, memoryBytes: ByteSize.gibibytes(12).bytes
      )
    )])
  }

  /// The document `runnerctl setup` writes must validate cleanly on a real host.
  @Test func theFullBlockAlsoValidates() throws {
    let (_, issues) = try ConfigLoader.loadAndValidate(
      yaml: Self.fullBlock, host: Fixtures.hostFacts)
    #expect(!issues.hasErrors)
  }

  @Test func absentKeysDecodeToDefaults() throws {
    let images = try ConfigLoader.load(yaml: Fixtures.minimalYAML).images
    #expect(images.updates == ImageUpdatePolicyConfig())
    #expect(images.updates.enabled == false)
    #expect(images.updates.interval == .hours(6))
    #expect(images.updates.jitter == .minutes(30))
    #expect(images.updates.keepPrevious == 1)
    #expect(images.updates.smokeTest)
    #expect(images.managed.isEmpty)
  }

  /// A partial `updates:` block leaves its siblings at their defaults rather than zeroing them.
  @Test func partialUpdatesBlockKeepsSiblingDefaults() throws {
    let images = try ConfigLoader.load(yaml: Self.withImages("  updates:\n    enabled: true\n")).images
    #expect(images.updates.enabled)
    #expect(images.updates.interval == ImageUpdatePolicyConfig().interval)
    #expect(images.updates.keepPrevious == ImageUpdatePolicyConfig().keepPrevious)
  }

  @Test func managedResourcesDefaultToTheKindDefaultsAndAutoUpdateIsOn() throws {
    let yaml = Self.withImages("""
        managed:
          - name: macos-tahoe-base
            kind: macos-tart
            source: ghcr.io/cirruslabs/macos-tahoe-base:latest
      """)
    let managed = try #require(ConfigLoader.load(yaml: yaml).images.managed.first)
    #expect(managed.autoUpdate)
    // Absent means "the kind's defaults", which is not the same as a zeroed block.
    #expect(managed.resources == nil)
    #expect(ManagedImageSourceConfig.Resources() == ManagedImageSourceConfig.Resources(
      cpuCount: 4, memoryBytes: ByteSize.gibibytes(8).bytes
    ))
  }

  @Test(arguments: ["macos-tart", "macosTart"])
  func bothKindSpellingsMapToTheSameEnum(_ spelling: String) throws {
    let yaml = Self.withImages("""
        managed:
          - name: macos-tahoe-base
            kind: \(spelling)
            source: ghcr.io/cirruslabs/macos-tahoe-base:latest
      """)
    #expect(try ConfigLoader.load(yaml: yaml).images.managed.first?.kind == .macosTart)
  }

  @Test func unknownKindIsRejectedWithItsPath() throws {
    let yaml = Self.withImages("""
        managed:
          - name: macos-tahoe-base
            kind: tart
            source: ghcr.io/cirruslabs/macos-tahoe-base:latest
      """)
    #expect(throws: ConfigLoadError.self) { try ConfigLoader.load(yaml: yaml) }
    guard case let .invalidValue(path, _) = errorFrom(yaml) else {
      Issue.record("expected invalidValue")
      return
    }
    #expect(path == "images.managed[0].kind")
  }

  @Test func aTypoInsideTheNewBlockIsRejectedRatherThanIgnored() throws {
    guard case let .unknownKey(path) = errorFrom(Self.withImages("  updates:\n    enable: true\n")) else {
      Issue.record("expected unknownKey")
      return
    }
    #expect(path == "images.updates.enable")
  }

  // MARK: - Wire compatibility

  /// The daemon persists `RunnerConfiguration` as JSON. A payload written before these fields
  /// existed must still decode, with the missing keys meaning "no managed sources, updates off".
  @Test func jsonWrittenBeforeTheseFieldsExistedStillDecodes() throws {
    let legacy = """
    {"maxSizeBytes":21474836480,"keepRecentlyUsed":"7d","prefetch":true,
     "limits":{"maxVirtualDiskBytes":549755813888,"maxLayers":4096}}
    """
    let images = try JSONDecoder().decode(ImageCacheConfig.self, from: Data(legacy.utf8))
    #expect(images.prefetch)
    #expect(images.maxSizeBytes == ByteSize.gibibytes(20).bytes)
    #expect(images.updates == ImageUpdatePolicyConfig())
    #expect(images.managed.isEmpty)
  }

  @Test func theNewFieldsSurviveAJSONRoundTrip() throws {
    let original = try ConfigLoader.load(yaml: Self.fullBlock)
    let decoded = try JSONDecoder().decode(
      RunnerConfiguration.self, from: JSONEncoder().encode(original))
    #expect(decoded.images == original.images)
  }

  // MARK: - Validation

  private func issues(_ yaml: String) throws -> [ConfigurationIssue] {
    try ConfigLoader.load(yaml: yaml).validate(host: Fixtures.hostFacts)
  }

  private func errorFrom(_ yaml: String) -> ConfigLoadError? {
    do {
      _ = try ConfigLoader.load(yaml: yaml)
      return nil
    } catch {
      return error
    }
  }

  @Test func intervalUnderFifteenMinutesIsRejectedOnlyWhileUpdatesAreEnabled() throws {
    let enabled = try issues(Self.withImages("  updates:\n    enabled: true\n    interval: 5m\n"))
    #expect(enabled.contains(code: "IMAGE_UPDATES_INTERVAL_TOO_SHORT"))
    let disabled = try issues(Self.withImages("  updates:\n    enabled: false\n    interval: 5m\n"))
    #expect(!disabled.contains(code: "IMAGE_UPDATES_INTERVAL_TOO_SHORT"))
    let atTheBoundary = try issues(Self.withImages("  updates:\n    enabled: true\n    interval: 15m\n"))
    #expect(!atTheBoundary.contains(code: "IMAGE_UPDATES_INTERVAL_TOO_SHORT"))
  }

  @Test(arguments: [-1, 6])
  func keepPreviousOutsideZeroToFiveIsRejected(_ value: Int) throws {
    let found = try issues(Self.withImages("  updates:\n    keepPrevious: \(value)\n"))
    #expect(found.contains(code: "IMAGE_UPDATES_KEEP_PREVIOUS_INVALID"))
  }

  @Test(arguments: [0, 5])
  func keepPreviousInsideZeroToFiveIsAccepted(_ value: Int) throws {
    let found = try issues(Self.withImages("  updates:\n    keepPrevious: \(value)\n"))
    #expect(!found.contains(code: "IMAGE_UPDATES_KEEP_PREVIOUS_INVALID"))
  }

  /// A negative duration cannot be spelled in YAML, so this rule is only reachable from a
  /// programmatically built configuration -- which is exactly what `runnerctl setup` builds.
  @Test func negativeJitterIsRejected() {
    var config = RunnerConfiguration()
    config.images.updates.jitter = .seconds(-1)
    #expect(config.validate(host: Fixtures.hostFacts).contains(code: "IMAGE_UPDATES_JITTER_NEGATIVE"))
  }

  @Test func managedNameEqualToAProfileNameIsRejected() throws {
    let yaml = Self.withImages("""
        managed:
          - name: ubuntu-24
            kind: registry-tag
            source: ghcr.io/acme/runners/ubuntu-24:stable
      """)
    #expect(try issues(yaml).contains(code: "MANAGED_IMAGE_NAME_COLLIDES_WITH_PROFILE"))
  }

  @Test func duplicateManagedNamesAreRejected() throws {
    let yaml = Self.withImages("""
        managed:
          - name: macos-tahoe-base
            kind: macos-tart
            source: ghcr.io/cirruslabs/macos-tahoe-base:latest
          - name: macos-tahoe-base
            kind: macos-tart
            source: ghcr.io/cirruslabs/macos-sequoia-base:latest
      """)
    #expect(try issues(yaml).contains(code: "MANAGED_IMAGE_DUPLICATE_NAME"))
  }

  @Test func aManagedNameThatCannotBeAnImageAliasIsRejected() throws {
    let yaml = Self.withImages("""
        managed:
          - name: MacOS Tahoe
            kind: macos-tart
            source: ghcr.io/cirruslabs/macos-tahoe-base:latest
      """)
    #expect(try issues(yaml).contains(code: "MANAGED_IMAGE_NAME_INVALID"))
  }

  @Test(arguments: ["macos-tahoe-base", ""])
  func aTartSourceThatIsNotARegistryReferenceIsRejected(_ source: String) throws {
    let yaml = Self.withImages("""
        managed:
          - name: macos-tahoe-base
            kind: macos-tart
            source: "\(source)"
      """)
    #expect(try issues(yaml).contains(code: "MANAGED_IMAGE_SOURCE_INVALID"))
  }

  /// A registry-tag source is not held to the same shape: only emptiness is refused.
  @Test func aRegistryTagSourceOnlyHasToBeNonEmpty() throws {
    let yaml = Self.withImages("""
        managed:
          - name: ubuntu-24-track
            kind: registry-tag
            source: local-name
      """)
    #expect(!(try issues(yaml).contains(code: "MANAGED_IMAGE_SOURCE_INVALID")))
  }

  @Test func aLinuxProfileNamingATartManagedImageIsRejected() throws {
    let yaml = """
    version: 1

    github:
      scopes:
        - name: engineering
          type: organization
          owner: acme

    images:
      managed:
        - name: macos-tahoe-base
          kind: macos-tart
          source: ghcr.io/cirruslabs/macos-tahoe-base:latest

    profiles:
      - name: ubuntu-24
        scope: engineering
        image: macos-tahoe-base
    """
    let found = try issues(yaml)
    #expect(found.contains(code: "MANAGED_IMAGE_REFERENCED_BY_NON_MACOS_PROFILE"))
    #expect(found.first(code: "MANAGED_IMAGE_REFERENCED_BY_NON_MACOS_PROFILE")?.path
      == "profiles[0].image")
  }

  @Test func aMacOSProfileNamingATartManagedImageIsAccepted() throws {
    let yaml = """
    version: 1

    github:
      scopes:
        - name: engineering
          type: organization
          owner: acme

    images:
      managed:
        - name: macos-tahoe-base
          kind: macos-tart
          source: ghcr.io/cirruslabs/macos-tahoe-base:latest

    profiles:
      - name: rvm-macos-tahoe
        scope: engineering
        image: macos-tahoe-base
        os: macos
        resources:
          cpu: 4
          memory: 8GiB
          disk: 60GiB
    """
    #expect(!(try issues(yaml).hasErrors))
  }
}
