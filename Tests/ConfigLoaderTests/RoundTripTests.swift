import ConfigLoader
import Foundation
import RunnerCore
import Testing

struct RoundTripTests {
  private static func jsonRoundTrip(_ config: RunnerConfiguration) throws -> RunnerConfiguration {
    let data = try JSONEncoder().encode(config)
    return try JSONDecoder().decode(RunnerConfiguration.self, from: data)
  }

  /// A document that leans entirely on defaults must map onto the identical `RunnerConfiguration`
  /// as one that spells every one of those defaults out explicitly.
  @Test func minimalAndExplicitYAMLMapToTheIdenticalConfiguration() throws {
    let minimal = try ConfigLoader.load(yaml: Fixtures.minimalYAML)

    let explicit = """
    version: 1
    host:
      reserve:
        cpu: 2
        memory: 6GiB
        disk: 50GiB
      overcommit:
        cpu: 1.0
        memory: 1.0
      maxVMs: auto
      limits:
        concurrentImagePulls: 2
        concurrentVMStarts: 2
    github:
      auth:
        provider: pat
        source: keychain
      scopes:
        - name: engineering
          type: organization
          owner: acme
    profiles:
      - name: ubuntu-24
        scope: engineering
        image: ghcr.io/acme/runners/ubuntu-24:stable
        os: linux
        lifecycle: ephemeral
        resources:
          cpu: 4
          memory: 8GiB
          disk: 80GiB
        warmPool:
          minIdle: 0
          maxIdle: 0
          idleTTL: 20m
        ssh:
          enabled: true
    """
    let explicitConfig = try ConfigLoader.load(yaml: explicit)
    #expect(minimal == explicitConfig)
  }

  @Test func loadedConfigurationSurvivesAJSONRoundTrip() throws {
    let config = try ConfigLoader.load(yaml: ExampleConfig.example)
    #expect(try Self.jsonRoundTrip(config) == config)
  }

  /// JSON-round-tripping the example must equal an independently loaded, differently-ordered
  /// YAML document that spells out every default the example leaves implicit.
  @Test func jsonRoundTripEqualsTheEquivalentYAMLMapping() throws {
    let fromExample = try ConfigLoader.load(yaml: ExampleConfig.example)
    let roundTripped = try Self.jsonRoundTrip(fromExample)

    let equivalent = """
    version: 1

    security:
      allowPublicRepositories: false

    diagnostics:
      failedInstanceRetention: 2h

    images:
      cache:
        keepRecentlyUsed: 7d

    metrics:
      prometheus:
        enabled: false
        listen: 127.0.0.1:9095

    github:
      auth:
        provider: pat
        source: keychain
      scopes:
        - name: engineering
          type: organization
          owner: acme
          runnerGroup: Default

    host:
      limits:
        concurrentImagePulls: 2
        concurrentVMStarts: 2
      reserve:
        disk: 50GiB
        cpu: 2
        memory: 6GiB
      overcommit:
        memory: 1.0
        cpu: 1.0
      maxVMs: auto

    profiles:
      - scope: engineering
        name: ubuntu-24
        os: linux
        image: ghcr.io/acme/runners/ubuntu-24:stable
        limits:
          maxInstances: 4
        ssh:
          enabled: true
        warmPool:
          idleTTL: 20m
          minIdle: 0
          maxIdle: 0
        resources:
          disk: 80GiB
          memory: 8GiB
          cpu: 4
        lifecycle: ephemeral
    """
    let mapping = try ConfigLoader.load(yaml: equivalent)
    #expect(roundTripped == mapping)
  }
}
