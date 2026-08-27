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

  # In-daemon image builds (Phase 4/5). Uncomment to override the defaults.
  # build:
  #   cpu: 4
  #   memory: 4GiB
  #   disk: 16GiB
  #   timeout: 60m
  #   stepTimeout: 30m
  #   maxConcurrent: 1
  #   recipeFileName: Runnerfile
  #   maxContextSize: 1GiB
  #   maxLogSize: 64MiB
  #   maxSteps: 256
  #   cache:                     # the FROM cloud-image: base cache, LRU-evicted
  #     maxBytes: 40GiB          # omit for "no size ceiling"
  #     minimumHostFreeBytes: 10GiB   # free space the cache refuses to eat into
  #     maxEntries: 4            # omit for "no count ceiling"
  """
}
