/// The spec §63 example configuration, verbatim except for one addition: `os: macos` on the
/// second profile. The spec's own example omits it because `os` is new since that section was
/// written; without it the profile would default to `linux` and fail resource validation (macOS
/// sizing vs. the linux minimum). `runnerctl config init` prints this so a fresh install starts
/// from a document that is already known to load and validate cleanly.
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

    - name: macos-15-xcode-16
      scope: engineering

      image: ghcr.io/acme/runners/macos-15-xcode-16:stable

      os: macos

      lifecycle: ephemeral

      resources:
        cpu: 6
        memory: 12GiB
        disk: 120GiB

      limits:
        maxInstances: 2

  metrics:
    prometheus:
      enabled: false
  """
}
