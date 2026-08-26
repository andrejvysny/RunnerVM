import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

struct RunnerVMArtifactTests {
  private static func chunk(index: Int, size: UInt64, seed: Character) -> OCIDescriptor {
    OCIDescriptor(
      mediaType: RunnerVMMediaType.diskChunk,
      digest: "sha256:" + String(repeating: seed, count: 64), size: Int64(size / 2),
      annotations: [
        RunnerVMAnnotation.chunkIndex: String(index),
        RunnerVMAnnotation.chunkUncompressedSize: String(size),
        RunnerVMAnnotation.chunkUncompressedDigest: "sha256:" + String(repeating: "9", count: 64),
      ]
    )
  }

  private static func manifest(
    chunks: [OCIDescriptor], nvram: OCIDescriptor? = nil, virtualSize: UInt64,
    configSize: Int64 = 64
  ) -> OCIManifest {
    RunnerVMArtifact.makeManifest(
      config: OCIDescriptor(
        mediaType: RunnerVMMediaType.config,
        digest: "sha256:" + String(repeating: "c", count: 64), size: configSize
      ),
      diskChunks: chunks, nvram: nvram, diskVirtualSize: virtualSize,
      diskContentDigest: "sha256:" + String(repeating: "f", count: 64), createdAt: Fixtures.createdAt
    )
  }

  @Test func mediaTypesAreProjectNamespaced() {
    #expect(RunnerVMMediaType.artifact == "application/vnd.runnervm.image.v1")
    #expect(RunnerVMMediaType.config == "application/vnd.runnervm.config.v1+json")
    #expect(RunnerVMMediaType.diskChunk == "application/vnd.runnervm.disk.raw.v1+lz4")
    #expect(RunnerVMMediaType.nvram(for: .linux) == "application/vnd.runnervm.efi.v1")
    #expect(RunnerVMMediaType.nvram(for: .macos) == "application/vnd.runnervm.macos.auxiliary-storage.v1")
  }

  @Test func configBlobIsFlatImageMetadataPlusASchemaVersion() throws {
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: 4096)
    let encoded = try RunnerVMConfig(metadata: metadata).encoded()
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["artifactSchemaVersion"] as? Int == 1)
    #expect(object["os"] as? String == "linux")
    #expect(object["virtualDiskSizeBytes"] as? UInt64 == 4096)
    #expect(try RunnerVMConfig.decode(encoded).metadata == metadata)
  }

  @Test func parsesAWellFormedManifest() throws {
    let metadata = Fixtures.linuxMetadata(virtualDiskSizeBytes: 3072)
    let nvram = OCIDescriptor(
      mediaType: RunnerVMMediaType.efi, digest: "sha256:" + String(repeating: "e", count: 64), size: 128
    )
    let manifest = Self.manifest(
      chunks: [Self.chunk(index: 0, size: 2048, seed: "a"), Self.chunk(index: 1, size: 1024, seed: "b")],
      nvram: nvram, virtualSize: 3072
    )
    let artifact = try RunnerVMArtifact.parse(
      manifest: manifest, configBlob: RunnerVMConfig(metadata: metadata).encoded()
    )
    #expect(artifact.diskChunks.count == 2)
    #expect(artifact.nvram == nvram)
    #expect(artifact.diskVirtualSize == 3072)
    #expect(artifact.metadata == metadata)
    #expect(artifact.createdAt == Fixtures.createdAt)
  }

  @Test func rejectsChunksOutOfOrder() throws {
    let manifest = Self.manifest(
      chunks: [Self.chunk(index: 1, size: 2048, seed: "a"), Self.chunk(index: 0, size: 1024, seed: "b")],
      virtualSize: 3072
    )
    #expect(throws: RegistryError.self) { try RunnerVMArtifact.layout(of: manifest) }
  }

  @Test func rejectsAnNVRAMLayerBeforeTheDiskChunks() throws {
    let manifest = OCIManifest(
      artifactType: RunnerVMMediaType.artifact,
      config: OCIDescriptor(
        mediaType: RunnerVMMediaType.config, digest: "sha256:" + String(repeating: "c", count: 64), size: 1
      ),
      layers: [
        OCIDescriptor(
          mediaType: RunnerVMMediaType.efi, digest: "sha256:" + String(repeating: "e", count: 64), size: 1
        ),
        Self.chunk(index: 0, size: 1024, seed: "a"),
      ]
    )
    #expect(throws: RegistryError.self) { try RunnerVMArtifact.layout(of: manifest) }
  }

  @Test func rejectsAForeignArtifactType() throws {
    var manifest = Self.manifest(chunks: [Self.chunk(index: 0, size: 1024, seed: "a")], virtualSize: 1024)
    manifest.artifactType = "application/vnd.cirruslabs.tart.config.v1"
    #expect(throws: RegistryError.self) { try RunnerVMArtifact.layout(of: manifest) }
  }

  @Test func rejectsChunkSizesThatDoNotAddUp() throws {
    let manifest = Self.manifest(chunks: [Self.chunk(index: 0, size: 1024, seed: "a")], virtualSize: 4096)
    #expect(throws: RegistryError.self) {
      try RunnerVMArtifact.parse(
        manifest: manifest,
        configBlob: RunnerVMConfig(metadata: Fixtures.linuxMetadata(virtualDiskSizeBytes: 4096)).encoded()
      )
    }
  }

  @Test func rejectsAnUnsupportedArtifactSchemaVersion() throws {
    let manifest = Self.manifest(chunks: [Self.chunk(index: 0, size: 1024, seed: "a")], virtualSize: 1024)
    let config = RunnerVMConfig(
      metadata: Fixtures.linuxMetadata(virtualDiskSizeBytes: 1024), artifactSchemaVersion: 99
    )
    #expect(throws: RegistryError.self) {
      try RunnerVMArtifact.parse(manifest: manifest, configBlob: config.encoded())
    }
  }

  @Test func rejectsNVRAMThatDoesNotMatchTheGuestOS() throws {
    let manifest = Self.manifest(
      chunks: [Self.chunk(index: 0, size: 1024, seed: "a")],
      nvram: OCIDescriptor(
        mediaType: RunnerVMMediaType.macOSAuxiliaryStorage,
        digest: "sha256:" + String(repeating: "e", count: 64), size: 1
      ),
      virtualSize: 1024
    )
    #expect(throws: RegistryError.self) {
      try RunnerVMArtifact.parse(
        manifest: manifest,
        configBlob: RunnerVMConfig(metadata: Fixtures.linuxMetadata(virtualDiskSizeBytes: 1024)).encoded()
      )
    }
  }
}
