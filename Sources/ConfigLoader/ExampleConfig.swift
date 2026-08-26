/// The spec §63 example configuration, minus its macOS profile: this build rejects `os: macos` at
/// validation time (`GUEST_OS_UNSUPPORTED`), so shipping one would make `runnerctl config init`
/// print a document that fails its own validation. `runnerctl config init` prints this so a fresh
/// install starts from a document that is already known to load and validate cleanly.
public enum ExampleConfig {
  public static let example = """
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

  github:
    auth:
      provider: pat
      source: keychain

    scopes:
      - name: engineering
        type: organization
        owner: acme
        runnerGroup: Default

  profiles:
    - name: ubuntu-24
      scope: engineering

      image: ghcr.io/acme/runners/ubuntu-24:stable

      lifecycle: ephemeral

      resources:
        cpu: 4
        memory: 8GiB
        disk: 80GiB

      warmPool:
        minIdle: 0
        maxIdle: 0
        idleTTL: 20m

      limits:
        maxInstances: 4

      ssh:
        enabled: true

  metrics:
    prometheus:
      enabled: false

  logging:
    file:
      enabled: true
      maxSize: 32MiB
      maxFiles: 10

    retention:
      instanceLogs: 7d

    collectRunnerDiagnostics: true
    diagnosticsTimeout: 60s
  """
}
