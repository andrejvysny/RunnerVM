/// The spec §63 example configuration, minus its macOS profile: `os: macos` validates now, but a
/// macOS profile is only usable once a macOS image has been imported, and it permanently claims
/// one of the host's two macOS guest slots -- neither is true of a fresh install. `runnerctl
/// config init` prints this so an install starts from a document that already loads, validates
/// cleanly, and can actually run what it declares.
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
      # Admission reserves each guest's *apparent* disk size, but an instance disk is an APFS
      # clone that only grows as the job writes. Raise above 1.0 only if you accept that a guest
      # which does fill its disk can exhaust host storage.
      disk: 1.0

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

  # Image update service (phase D6) and managed image sources (phase D7). Accepted and validated
  # now, acted on once those phases land. Uncomment to declare them ahead of time.
  # images:
  #   prefetch: true            # pull every profile image at `config apply`, not at first job
  #   updates:
  #     enabled: true
  #     interval: 6h            # at least 15m while enabled
  #     jitter: 30m             # spread, so a fleet does not check in lockstep
  #     keepPrevious: 1         # superseded digests kept; the only deletion trigger
  #     smokeTest: true         # qualify a candidate before promoting it
  #   managed:                  # sources RunnerVM keeps current on the host's own behalf
  #     - name: macos-tahoe-base      # local alias a macOS profile names in `image:`
  #       kind: macos-tart            # a Tart export: never runnable as pulled, always provisioned
  #       source: ghcr.io/cirruslabs/macos-tahoe-base:latest
  #       autoUpdate: true
  #       resources:                  # the provisioning VM's sizing, not the runner's
  #         cpu: 4
  #         memory: 8GiB

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
