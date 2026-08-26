import Foundation
import Testing

@testable import RunnerCore

/// `metadata.json` is written by `scripts/build-ubuntu-image.sh` and read back by
/// `runnerctl image import`, so the two ends have to agree about a file that gains fields over
/// time. Provenance is additive: every image sealed before it existed must still decode.
@Suite struct ImageMetadataProvenanceTests {
  private static func coders() -> (JSONEncoder, JSONDecoder) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (encoder, decoder)
  }

  private static func metadata(provenance: ImageMetadata.Provenance?) -> ImageMetadata {
    ImageMetadata(
      os: .linux, virtualDiskSizeBytes: 17_179_869_184, runnerVersion: "2.331.0",
      guestAgentVersion: "v0.1.0", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(docker: true, ssh: true),
      provenance: provenance)
  }

  private static let full = ImageMetadata.Provenance(
    baseImage: ImageMetadata.Provenance.BaseImage(
      source: "https://cloud-images.ubuntu.com/noble.img", sha256: "sha256:aa"),
    actionsRunner: ImageMetadata.Provenance.ActionsRunner(
      version: "2.331.0", sha256: "sha256:bb", url: "https://example.invalid/runner.tar.gz"),
    guestAgent: ImageMetadata.Provenance.GuestAgent(
      gitCommit: "3fb473c", sha256: "sha256:cc", reportedVersion: "runnervm-guest-agent v0.1.0"),
    builder: ImageMetadata.Provenance.Builder(
      gitCommit: "3fb473c", script: "scripts/build-ubuntu-image.sh", hostOSVersion: "26.4",
      builtAt: "2026-08-26T10:00:00Z"),
    docker: ImageMetadata.Provenance.Docker(
      repository: "https://download.docker.com/linux/ubuntu noble stable", version: "5:27.3.1"),
    packageUpgrade: true, packages: ["git=1:2.43.0", "jq=1.7.1"],
    kernelVersion: "6.8.0-51-generic", diskSHA256: "sha256:dd")

  @Test func provenanceRoundTrips() throws {
    let (encoder, decoder) = Self.coders()
    let original = Self.metadata(provenance: Self.full)
    let decoded = try decoder.decode(ImageMetadata.self, from: try encoder.encode(original))
    #expect(decoded == original)
    #expect(decoded.provenance?.packages?.count == 2)
    #expect(decoded.provenance?.diskSHA256 == "sha256:dd")
  }

  /// The whole reason `schemaVersion` stays at 1: a file written before provenance existed has no
  /// `provenance` key at all, and must decode into `nil` rather than fail.
  @Test func metadataSealedBeforeProvenanceStillDecodes() throws {
    let (_, decoder) = Self.coders()
    let legacy = """
      {"architecture":"arm64","boot":{"type":"efi"},"capabilities":{"docker":true,"ssh":true},\
      "createdAt":"2026-08-20T08:00:00Z","diskFormat":"raw","guestAgentVersion":"v0.1.0",\
      "minimumHostOS":"15.0","os":"linux","runnerVersion":"2.330.0","schemaVersion":1,\
      "virtualDiskSizeBytes":17179869184}
      """
    let decoded = try decoder.decode(ImageMetadata.self, from: Data(legacy.utf8))
    #expect(decoded.provenance == nil)
    #expect(decoded.runnerVersion == "2.330.0")
    #expect(decoded.capabilities.docker)
  }

  /// A build that could not resolve one input records the ones it could. Every provenance field is
  /// individually optional, so a half-filled block is still readable.
  @Test func provenanceToleratesMissingFields() throws {
    let (_, decoder) = Self.coders()
    let partial = """
      {"architecture":"arm64","boot":{"type":"efi"},"capabilities":{"docker":true,"ssh":false},\
      "createdAt":"2026-08-20T08:00:00Z","diskFormat":"raw","minimumHostOS":"15.0","os":"linux",\
      "provenance":{"baseImage":{"sha256":"sha256:aa"},"packageUpgrade":false},\
      "schemaVersion":1,"virtualDiskSizeBytes":1024}
      """
    let decoded = try decoder.decode(ImageMetadata.self, from: Data(partial.utf8))
    #expect(decoded.provenance?.baseImage?.sha256 == "sha256:aa")
    #expect(decoded.provenance?.baseImage?.source == nil)
    #expect(decoded.provenance?.packageUpgrade == false)
    #expect(decoded.provenance?.packages == nil)
    #expect(decoded.provenance?.actionsRunner == nil)
  }

  /// Byte-for-byte what `scripts/build-ubuntu-image.sh` seals, keys sorted the way `jq --sort-keys`
  /// emits them. If this stops decoding, the script and the model have drifted apart.
  @Test func aSealedMetadataFileFromTheBuildScriptDecodes() throws {
    let (_, decoder) = Self.coders()
    let decoded = try decoder.decode(ImageMetadata.self, from: Data(Self.sealedFixture.utf8))
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.os == .linux)
    #expect(decoded.runnerVersion == "2.331.0")
    #expect(decoded.provenance?.actionsRunner?.version == "2.331.0")
    #expect(decoded.provenance?.baseImage?.sha256
      == "sha256:ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7")
    #expect(decoded.provenance?.builder?.script == "scripts/build-ubuntu-image.sh")
    #expect(decoded.provenance?.docker?.version == "5:27.3.1-1~ubuntu.24.04~noble")
    #expect(decoded.provenance?.packages?.count == 3)
    #expect(decoded.provenance?.kernelVersion == "6.8.0-51-generic")
    #expect(decoded.provenance?.diskSHA256?.hasPrefix("sha256:") == true)
  }

  private static let sealedFixture = """
    {
      "architecture": "arm64",
      "boot": { "type": "efi" },
      "capabilities": { "docker": true, "ssh": true },
      "createdAt": "2026-08-26T10:00:00Z",
      "diskFormat": "raw",
      "guestAgentVersion": "v0.1.0-12-g3fb473c",
      "minimumHostOS": "15.0",
      "os": "linux",
      "provenance": {
        "actionsRunner": {
          "sha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
          "url": "https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-arm64-2.331.0.tar.gz",
          "version": "2.331.0"
        },
        "baseImage": {
          "sha256": "sha256:ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7",
          "source": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
        },
        "builder": {
          "builtAt": "2026-08-26T10:00:00Z",
          "gitCommit": "3fb473c50107af5909c377dd581e9ff8915b557c",
          "hostOSVersion": "26.4",
          "script": "scripts/build-ubuntu-image.sh"
        },
        "diskSHA256": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        "docker": {
          "repository": "https://download.docker.com/linux/ubuntu noble stable",
          "version": "5:27.3.1-1~ubuntu.24.04~noble"
        },
        "guestAgent": {
          "gitCommit": "3fb473c50107af5909c377dd581e9ff8915b557c",
          "reportedVersion": "runnervm-guest-agent v0.1.0 (linux/arm64)",
          "sha256": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
        },
        "kernelVersion": "6.8.0-51-generic",
        "packageUpgrade": true,
        "packages": [
          "git=1:2.43.0-1ubuntu7",
          "jq=1.7.1-3build1",
          "docker-ce=5:27.3.1-1~ubuntu.24.04~noble"
        ]
      },
      "runnerVersion": "2.331.0",
      "schemaVersion": 1,
      "virtualDiskSizeBytes": 17179869184
    }
    """
}
