import RunnerCore

enum Fixtures {
  /// Per the ConfigLoader task spec: 12 logical CPUs, 64 GiB, generous VZ bounds around it.
  static let hostFacts = HostFacts(
    logicalCPUCount: 12,
    physicalMemoryBytes: ByteSize.gibibytes(64).bytes,
    minimumAllowedCPUCount: 1,
    maximumAllowedCPUCount: 64,
    minimumAllowedMemoryBytes: ByteSize.mebibytes(4).bytes,
    maximumAllowedMemoryBytes: ByteSize.gibibytes(64).bytes
  )

  /// Minimal-but-complete document: one scope, one linux profile, everything else defaulted.
  static let minimalYAML = """
  version: 1

  github:
    scopes:
      - name: engineering
        type: organization
        owner: acme

  profiles:
    - name: ubuntu-24
      scope: engineering
      image: ghcr.io/acme/runners/ubuntu-24:stable
  """
}
