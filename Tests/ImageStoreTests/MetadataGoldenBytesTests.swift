import Foundation
import RunnerCore
import Testing
@testable import ImageStore

/// Adding an optional field to `ImageMetadata`/`Provenance` must never change what an
/// already-sealed `metadata.json` re-encodes as: `images.metadata_json` and every image already on
/// disk were written by whatever model version runnerd shipped at seal time. These pin the exact
/// bytes the model produced before T6 added `Capabilities.guestAgent`/`labels`,
/// `Provenance.imported`/`recipe`/`parentImageDigest` and `BaseImage.rawSHA256` (captured by
/// encoding with the pre-change code), so a synthesized-`Codable` slip -- an `encode` instead of
/// `encodeIfPresent`, say -- fails loudly instead of silently drifting every image's digest.
@Suite struct MetadataGoldenBytesTests {
  private static let createdAt = Date(timeIntervalSince1970: 1_756_000_000)

  private static func metadata(provenance: ImageMetadata.Provenance? = nil) -> ImageMetadata {
    ImageMetadata(
      os: .linux, architecture: "arm64", virtualDiskSizeBytes: 32 << 20, runnerVersion: "2.331.0",
      guestAgentVersion: "v0.1.0-12-g3fb473c", minimumHostOS: "15.0", createdAt: createdAt,
      boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(docker: true, ssh: true),
      provenance: provenance
    )
  }

  @Test func noNewFieldsEncodesToTheExactPreExistingBytes() throws {
    let bytes = try CanonicalJSON.encode(Self.metadata())
    #expect(String(decoding: bytes, as: UTF8.self) == Self.expectedNoFields)
  }

  @Test func anExistingProvenanceObjectAlsoEncodesUnchanged() throws {
    let provenance = ImageMetadata.Provenance(
      baseImage: ImageMetadata.Provenance.BaseImage(
        source: "https://cloud-images.ubuntu.com/noble.img", sha256: "sha256:aa"),
      actionsRunner: ImageMetadata.Provenance.ActionsRunner(
        version: "2.331.0", sha256: "sha256:bb", url: "https://example.invalid/runner.tar.gz",
        digestSource: "github-release-asset"),
      guestAgent: ImageMetadata.Provenance.GuestAgent(
        gitCommit: "3fb473c", sha256: "sha256:cc", reportedVersion: "v0.1.0-12-g3fb473c"),
      builder: ImageMetadata.Provenance.Builder(
        gitCommit: "deadbee", script: "scripts/build-ubuntu-image.sh", hostOSVersion: "15.4.0",
        builtAt: "2026-08-26T10:00:00Z"),
      docker: ImageMetadata.Provenance.Docker(
        repository: "https://download.docker.com/linux/ubuntu noble stable", version: "5:27.3.1"),
      packageUpgrade: true, packages: ["git=1:2.43.0", "jq=1.7.1"],
      kernelVersion: "6.8.0-51-generic", diskSHA256: "sha256:dd"
    )
    let bytes = try CanonicalJSON.encode(Self.metadata(provenance: provenance))
    #expect(String(decoding: bytes, as: UTF8.self) == Self.expectedWithProvenance)
  }

  // Captured by encoding with the pre-T6 models; see the doc comment above.
  private static let expectedNoFields = "{\"architecture\":\"arm64\",\"boot\":{\"type\":\"efi\"},\"capabilities\":{\"docker\":true,\"ssh\":true},\"createdAt\":\"2025-08-24T01:46:40Z\",\"diskFormat\":\"raw\",\"guestAgentVersion\":\"v0.1.0-12-g3fb473c\",\"minimumHostOS\":\"15.0\",\"os\":\"linux\",\"runnerVersion\":\"2.331.0\",\"schemaVersion\":1,\"virtualDiskSizeBytes\":33554432}"

  private static let expectedWithProvenance = "{\"architecture\":\"arm64\",\"boot\":{\"type\":\"efi\"},\"capabilities\":{\"docker\":true,\"ssh\":true},\"createdAt\":\"2025-08-24T01:46:40Z\",\"diskFormat\":\"raw\",\"guestAgentVersion\":\"v0.1.0-12-g3fb473c\",\"minimumHostOS\":\"15.0\",\"os\":\"linux\",\"provenance\":{\"actionsRunner\":{\"digestSource\":\"github-release-asset\",\"sha256\":\"sha256:bb\",\"url\":\"https://example.invalid/runner.tar.gz\",\"version\":\"2.331.0\"},\"baseImage\":{\"sha256\":\"sha256:aa\",\"source\":\"https://cloud-images.ubuntu.com/noble.img\"},\"builder\":{\"builtAt\":\"2026-08-26T10:00:00Z\",\"gitCommit\":\"deadbee\",\"hostOSVersion\":\"15.4.0\",\"script\":\"scripts/build-ubuntu-image.sh\"},\"diskSHA256\":\"sha256:dd\",\"docker\":{\"repository\":\"https://download.docker.com/linux/ubuntu noble stable\",\"version\":\"5:27.3.1\"},\"guestAgent\":{\"gitCommit\":\"3fb473c\",\"reportedVersion\":\"v0.1.0-12-g3fb473c\",\"sha256\":\"sha256:cc\"},\"kernelVersion\":\"6.8.0-51-generic\",\"packageUpgrade\":true,\"packages\":[\"git=1:2.43.0\",\"jq=1.7.1\"]},\"runnerVersion\":\"2.331.0\",\"schemaVersion\":1,\"virtualDiskSizeBytes\":33554432}"
}
