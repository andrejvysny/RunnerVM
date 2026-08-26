import ConfigLoader
import RunnerCore
import Testing

/// One test per `ConfigLoadError` case, each pinned to the exact YAML shape that triggers it.
struct ErrorTests {
  private static func load(_ yaml: String) -> Result<RunnerConfiguration, ConfigLoadError> {
    do {
      return try .success(ConfigLoader.load(yaml: yaml))
    } catch {
      return .failure(error)
    }
  }

  @Test func malformedYAMLProducesYamlSyntax() {
    // Unterminated double-quoted scalar: never a valid document, regardless of schema.
    let yaml = """
    version: 1
    host:
      reserve:
        memory: "6GiB
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected a syntax failure")
      return
    }
    guard case let .yamlSyntax(line, _, message) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(line > 0)
    #expect(!message.isEmpty)
    #expect(error.code == "CONFIG_YAML_SYNTAX")
  }

  @Test func unrecognizedNestedKeyProducesUnknownKey() {
    let yaml = """
    version: 1
    host:
      reserve:
        cpu: 2
        bogus: 1
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an unknown-key failure")
      return
    }
    guard case let .unknownKey(path) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "host.reserve.bogus")
    #expect(error.code == "CONFIG_UNKNOWN_KEY")
  }

  @Test func unrecognizedImageUpdatesKeyProducesUnknownKey() {
    let yaml = """
    version: 1
    imageUpdates:
      bogus: true
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an unknown-key failure")
      return
    }
    guard case let .unknownKey(path) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "imageUpdates.bogus")
  }

  @Test func unrecognizedReuseKeyProducesUnknownKey() {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        reuse:
          bogus: 1
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an unknown-key failure")
      return
    }
    guard case let .unknownKey(path) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "profiles[0].reuse.bogus")
  }

  @Test func profileMissingNameProducesMissingKey() {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected a missing-key failure")
      return
    }
    guard case let .missingKey(path) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "profiles[0].name")
  }

  @Test func scopeMissingTypeProducesMissingKey() {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, owner: acme}
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected a missing-key failure")
      return
    }
    guard case let .missingKey(path) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "github.scopes[0].type")
  }

  @Test func malformedByteSizeProducesInvalidValue() {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        resources:
          memory: 8GB?
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an invalid-value failure")
      return
    }
    guard case let .invalidValue(path, reason) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "profiles[0].resources.memory")
    #expect(!reason.isEmpty)
    #expect(error.code == "CONFIG_INVALID_VALUE")
  }

  @Test func malformedDurationProducesInvalidValue() {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        warmPool:
          idleTTL: 20x
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an invalid-value failure")
      return
    }
    guard case let .invalidValue(path, reason) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(path == "profiles[0].warmPool.idleTTL")
    #expect(reason.contains("invalid duration"))
  }

  @Test func unsupportedVersionIsRejectedBeforeMapping() {
    let yaml = """
    version: 2
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    """
    guard case let .failure(error) = Self.load(yaml) else {
      Issue.record("expected an unsupported-version failure")
      return
    }
    guard case let .unsupportedVersion(found) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(found == 2)
    #expect(error.code == "CONFIG_UNSUPPORTED_VERSION")
  }

  @Test func macOSProfileBelowMinimumCPUFailsValidationNotLoad() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: macos-15
        scope: engineering
        image: ghcr.io/acme/runners/macos-15:stable
        os: macos
        resources:
          cpu: 2
    """
    // Loading alone (no host facts) succeeds: the value is well-formed, just out of range.
    let config = try ConfigLoader.load(yaml: yaml)
    #expect(config.profile(named: "macos-15")?.resources.cpuCount == 2)

    let error = #expect(throws: ConfigLoadError.self) {
      try ConfigLoader.loadAndValidate(yaml: yaml, host: Fixtures.hostFacts)
    }
    let loadError = try #require(error)
    guard case let .validationFailed(issues) = loadError else {
      Issue.record("unexpected error \(loadError)")
      return
    }
    #expect(issues.contains(code: "PROFILE_CPU_BELOW_MACOS_MINIMUM"))
    #expect(loadError.code == "CONFIG_VALIDATION_FAILED")
  }

  @Test func macOSProfileFailsValidationAsUnsupportedGuestOS() throws {
    let yaml = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    profiles:
      - name: macos-15
        scope: engineering
        image: ghcr.io/acme/runners/macos-15:stable
        os: macos
    """
    // Loading alone succeeds: `os: macos` is a well-formed value, just unsupported in this build.
    let config = try ConfigLoader.load(yaml: yaml)
    #expect(config.profile(named: "macos-15")?.guestOS == .macos)

    let error = #expect(throws: ConfigLoadError.self) {
      try ConfigLoader.loadAndValidate(yaml: yaml, host: Fixtures.hostFacts)
    }
    let loadError = try #require(error)
    guard case let .validationFailed(issues) = loadError else {
      Issue.record("unexpected error \(loadError)")
      return
    }
    let issue = try #require(issues.first(code: "GUEST_OS_UNSUPPORTED"))
    #expect(issue.path == "profiles[0].os")
  }
}
