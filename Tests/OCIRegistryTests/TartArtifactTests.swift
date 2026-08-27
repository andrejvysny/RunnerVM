import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

/// Spec §58. Every structural (S1–S9) and semantic (C2–C8) rule the importer enforces has a
/// failing case here, and all of them are decided from the manifest plus two config blobs — no
/// disk chunk is ever fetched, because nothing in this suite talks to a registry at all.
struct TartArtifactTests {
  static let uploadTime = "2026-08-01T12:00:00Z"
  static let manifestDigest = digest("d")

  static func digest(_ seed: Character) -> String {
    "sha256:" + String(repeating: seed, count: 64)
  }

  static func layer(_ mediaType: String, _ seed: Character, size: Int64) -> OCIDescriptor {
    OCIDescriptor(mediaType: mediaType, digest: digest(seed), size: size)
  }

  static let vmConfigLayer = layer(TartMediaType.config, "1", size: 200)
  static let nvramLayer = layer(TartMediaType.nvram, "2", size: 4096)
  static let ociConfigDescriptor = layer(TartMediaType.ociConfig, "3", size: 96)

  static func chunk(
    _ seed: Character, size: UInt64, mediaType: String = TartMediaType.diskV2,
    annotations: [String: String]? = nil
  ) -> OCIDescriptor {
    OCIDescriptor(
      mediaType: mediaType, digest: digest(seed), size: Int64(size / 2),
      annotations: annotations ?? [
        TartAnnotation.uncompressedSize: String(size),
        TartAnnotation.uncompressedContentDigest: digest("9"),
      ]
    )
  }

  static func chunks(_ sizes: [UInt64] = [2048, 1024]) -> [OCIDescriptor] {
    sizes.enumerated().map { chunk(Character(UnicodeScalar(97 + UInt8($0.offset))), size: $0.element) }
  }

  static func annotations(
    diskSize: UInt64? = 3072, uploadTime: String? = TartArtifactTests.uploadTime
  ) -> [String: String] {
    var result: [String: String] = [:]
    if let diskSize { result[TartAnnotation.uncompressedDiskSize] = String(diskSize) }
    if let uploadTime { result[TartAnnotation.uploadTime] = uploadTime }
    return result
  }

  static func manifest(
    layers: [OCIDescriptor], config: OCIDescriptor = ociConfigDescriptor,
    annotations: [String: String]? = TartArtifactTests.annotations(),
    schemaVersion: Int = 2, mediaType: String = RunnerVMMediaType.ociManifest
  ) -> OCIManifest {
    OCIManifest(
      schemaVersion: schemaVersion, mediaType: mediaType, config: config, layers: layers,
      annotations: annotations
    )
  }

  /// The canonical flat linux shape: tart config, N `disk.v2` chunks, NVRAM.
  static func flat(
    _ sizes: [UInt64] = [2048, 1024], annotations: [String: String]? = TartArtifactTests.annotations()
  ) -> OCIManifest {
    manifest(layers: [vmConfigLayer] + chunks(sizes) + [nvramLayer], annotations: annotations)
  }

  @discardableResult
  static func parse(
    _ manifest: OCIManifest, vmConfig: Data = Data(TartFixtures.linuxConfigJSON.utf8),
    ociConfig: Data = TartFixtures.ociConfig()
  ) throws -> TartArtifact {
    try TartArtifact.parse(
      manifest: manifest, ociConfigBlob: ociConfig, vmConfigBlob: vmConfig,
      manifestDigest: manifestDigest
    )
  }

  // MARK: - Constants

  @Test func mediaTypesAndAnnotationsMatchTart() {
    #expect(TartMediaType.ociConfig == "application/vnd.oci.image.config.v1+json")
    #expect(TartMediaType.config == "application/vnd.cirruslabs.tart.config.v1")
    #expect(TartMediaType.diskV2 == "application/vnd.cirruslabs.tart.disk.v2")
    #expect(TartMediaType.legacyDiskV1 == "application/vnd.cirruslabs.tart.disk.v1")
    #expect(TartMediaType.asifOverlay == "application/vnd.cirruslabs.tart.disk.asif.overlay.v1")
    #expect(TartMediaType.nvram == "application/vnd.cirruslabs.tart.nvram.v1")
    #expect(TartAnnotation.uncompressedDiskSize == "org.cirruslabs.tart.uncompressed-disk-size")
    #expect(TartAnnotation.uploadTime == "org.cirruslabs.tart.upload-time")
    #expect(TartAnnotation.diskBlockSize == "org.cirruslabs.tart.disk.block-size")
    #expect(TartAnnotation.diskFormatLabel == "org.cirruslabs.tart.disk.format")
    #expect(TartAnnotation.uncompressedSize == "org.cirruslabs.tart.uncompressed-size")
    #expect(
      TartAnnotation.uncompressedContentDigest == "org.cirruslabs.tart.uncompressed-content-digest")
    #expect(TartAnnotation.diskFileContentDigest == "org.cirruslabs.tart.disk-file-content-digest")
    #expect(TartAnnotation.diskFileChunkCount == "org.cirruslabs.tart.disk-file-chunk-count")
    #expect(ChunkAnnotationKeys.tart.uncompressedSize == TartAnnotation.uncompressedSize)
    #expect(ChunkAnnotationKeys.tart.uncompressedDigest == TartAnnotation.uncompressedContentDigest)
  }

  // MARK: - Happy path

  @Test func parsesAFlatLinuxManifest() throws {
    let artifact = try Self.parse(Self.flat())

    #expect(artifact.diskChunks.map(\.offset) == [0, 2048])
    #expect(artifact.diskChunks.map(\.uncompressedSize) == [2048, 1024])
    #expect(artifact.diskVirtualSize == 3072)
    #expect(artifact.nvram == Self.nvramLayer)
    #expect(artifact.vmConfigLayer == Self.vmConfigLayer)
    #expect(artifact.createdAt == ISO8601DateFormatter().date(from: Self.uploadTime))
    #expect(artifact.metadata.os == .linux)
    #expect(artifact.metadata.architecture == "arm64")
    #expect(artifact.metadata.diskFormat == .raw)
    #expect(artifact.metadata.boot.type == .efi)
    #expect(artifact.metadata.macos == nil)
    #expect(artifact.metadata.virtualDiskSizeBytes == 3072)
    #expect(artifact.metadata.minimumHostOS == "15.0")
    #expect(artifact.metadata.runnerVersion == nil)
    #expect(artifact.metadata.guestAgentVersion == nil)
    #expect(artifact.metadata.capabilities.guestAgent == false)
    #expect(artifact.metadata.capabilities.docker == false)
    #expect(artifact.metadata.capabilities.ssh)
    #expect(artifact.metadata.hasGuestAgent == false)
  }

  /// `createdAt` feeds the local content digest, so it must be a constant rather than "now" when
  /// the manifest does not say.
  @Test func anAbsentUploadTimeFallsBackToTheEpochNotTheClock() throws {
    let artifact = try Self.parse(Self.flat(annotations: Self.annotations(uploadTime: nil)))

    #expect(artifact.createdAt == Date(timeIntervalSince1970: 0))
    #expect(artifact.metadata.createdAt == Date(timeIntervalSince1970: 0))
  }

  /// Same bytes, same identity: the only thing an upload timestamp may change is `createdAt`.
  @Test func upladTimeIsTheOnlyDifferenceItCanMake() throws {
    var stamped = try Self.parse(Self.flat()).metadata
    let unstamped = try Self.parse(Self.flat(annotations: Self.annotations(uploadTime: nil))).metadata

    #expect(stamped.createdAt != unstamped.createdAt)
    stamped.createdAt = unstamped.createdAt
    #expect(stamped == unstamped)
  }

  @Test func aDarwinManifestBecomesAMacOSImageWithItsHardwareModel() throws {
    let artifact = try Self.parse(
      Self.flat(), vmConfig: Data(TartFixtures.darwinConfigJSON.utf8),
      ociConfig: TartFixtures.ociConfig(os: "darwin")
    )

    #expect(artifact.metadata.os == .macos)
    #expect(artifact.metadata.boot.type == .macos)
    #expect(artifact.metadata.macos?.hardwareModel == TartFixtures.hardwareModel)
  }

  /// Spec §24: instance identity must never survive into image metadata.
  @Test func theEncodedMetadataCarriesNeitherTheECIDNorTheMACAddress() throws {
    let artifact = try Self.parse(
      Self.flat(), vmConfig: Data(TartFixtures.darwinConfigJSON.utf8),
      ociConfig: TartFixtures.ociConfig(os: "darwin")
    )
    let encoded = String(decoding: try JSONEncoder().encode(artifact.metadata), as: UTF8.self)

    #expect(!encoded.contains("6a:3e:f1:99:18:c1"))
    #expect(!encoded.contains(TartFixtures.ecid))
    #expect(!encoded.contains("ecid"))
    #expect(encoded.contains(TartFixtures.hardwareModel))
  }

  /// The identity must be mirror-neutral: the same image pulled from two registries has to import
  /// under one content digest, so no reference string may reach the metadata.
  @Test func theMetadataNeverCarriesAReferenceString() throws {
    let artifact = try Self.parse(Self.flat())
    let encoded = String(decoding: try JSONEncoder().encode(artifact.metadata), as: UTF8.self)

    #expect(!encoded.contains("ghcr.io"))
    #expect(!encoded.contains("cirruslabs/ubuntu"))
    #expect(encoded.contains(Self.manifestDigest)) // provenance only
  }

  @Test func theSizingHintsSurviveInProvenance() throws {
    let imported = try #require(try Self.parse(Self.flat()).metadata.provenance?.imported)

    #expect(imported.format == "tart")
    #expect(imported.manifestDigest == Self.manifestDigest)
    #expect(imported.tartConfig?.version == 1)
    #expect(imported.tartConfig?.cpuCount == 4)
    #expect(imported.tartConfig?.cpuCountMin == 4)
    #expect(imported.tartConfig?.memorySize == 4_294_967_296)
    #expect(imported.tartConfig?.memorySizeMin == 4_294_967_296)
    #expect(imported.tartConfig?.displayWidth == 1024)
    #expect(imported.tartConfig?.displayHeight == 768)
    #expect(imported.tartConfig?.diskFormat == "raw")
  }

  @Test func looksLikeTartOnlyAcceptsTheConfigPlusOCIConfigShape() {
    #expect(TartArtifact.looksLikeTart(Self.flat()))
    #expect(
      !TartArtifact.looksLikeTart(
        Self.manifest(layers: [Self.vmConfigLayer] + Self.chunks() + [Self.nvramLayer],
                      config: Self.layer(RunnerVMMediaType.config, "3", size: 96))))
    #expect(
      !TartArtifact.looksLikeTart(
        Self.manifest(layers: Self.chunks() + [Self.nvramLayer])))
  }

  // MARK: - Structural rules S1–S9

  @Test func s1RefusesAnythingThatIsNotAnOCIImageManifest() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(layers: [Self.vmConfigLayer] + Self.chunks() + [Self.nvramLayer],
                      schemaVersion: 1))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(layers: [Self.vmConfigLayer] + Self.chunks() + [Self.nvramLayer],
                      mediaType: RunnerVMMediaType.ociIndex))
    }
  }

  @Test func s2RefusesAConfigDescriptorThatIsNotAnOCIImageConfig() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(
          layers: [Self.vmConfigLayer] + Self.chunks() + [Self.nvramLayer],
          config: Self.layer(RunnerVMMediaType.config, "3", size: 96)))
    }
  }

  @Test func s3RefusesTheLegacyDiskV1Layer() throws {
    let legacy = Self.chunk("a", size: 2048, mediaType: TartMediaType.legacyDiskV1)
    let error = #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(layers: [Self.vmConfigLayer, legacy, Self.nvramLayer],
                      annotations: Self.annotations(diskSize: 2048)))
    }
    #expect(error?.message.contains("tart ≥2") == true)
  }

  @Test func s4RequiresExactlyOneTartConfigLayerAndItMustBeFirst() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(
          layers: [Self.vmConfigLayer, Self.chunk("a", size: 3072),
                   Self.layer(TartMediaType.config, "4", size: 200), Self.nvramLayer]))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(
          layers: [Self.chunk("a", size: 3072), Self.vmConfigLayer, Self.nvramLayer]))
    }
  }

  @Test func s5RequiresExactlyOneNVRAMLayerAndItMustBeLast() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(
          layers: [Self.vmConfigLayer, Self.chunk("a", size: 3072), Self.nvramLayer,
                   Self.layer(TartMediaType.nvram, "5", size: 4096)]))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(
          layers: [Self.vmConfigLayer, Self.nvramLayer, Self.chunk("a", size: 3072)]))
    }
  }

  @Test func s6RefusesAManifestWithNoDiskChunks() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(layers: [Self.vmConfigLayer, Self.nvramLayer],
                      annotations: Self.annotations(diskSize: 0)))
    }
  }

  @Test func s7NamesASIFAndRefusesAnyOtherChunkMediaType() throws {
    let overlay = Self.chunk("a", size: 3072, mediaType: TartMediaType.asifOverlay)
    let asif = #expect(throws: RegistryError.self) {
      try Self.parse(Self.manifest(layers: [Self.vmConfigLayer, overlay, Self.nvramLayer]))
    }
    #expect(asif?.message.contains("ASIF") == true)

    let foreign = Self.chunk("a", size: 3072, mediaType: RunnerVMMediaType.diskChunk)
    let other = #expect(throws: RegistryError.self) {
      try Self.parse(Self.manifest(layers: [Self.vmConfigLayer, foreign, Self.nvramLayer]))
    }
    #expect(other?.message.contains("unsupported disk chunk media type") == true)
  }

  @Test func s8RefusesAStackedImage() throws {
    let stacked = Self.chunk(
      "a", size: 3072,
      annotations: [
        TartAnnotation.uncompressedSize: "3072",
        TartAnnotation.uncompressedContentDigest: Self.digest("9"),
        TartAnnotation.diskFileContentDigest: Self.digest("8"),
        TartAnnotation.diskFileChunkCount: "1",
      ]
    )
    let error = #expect(throws: RegistryError.self) {
      try Self.parse(Self.manifest(layers: [Self.vmConfigLayer, stacked, Self.nvramLayer]))
    }
    #expect(error?.message.contains("stacked") == true)
  }

  @Test func s9RequiresBothChunkAnnotations() {
    let noSize = Self.chunk(
      "a", size: 3072, annotations: [TartAnnotation.uncompressedContentDigest: Self.digest("9")])
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.manifest(layers: [Self.vmConfigLayer, noSize, Self.nvramLayer]))
    }
    let noDigest = Self.chunk(
      "a", size: 3072, annotations: [TartAnnotation.uncompressedSize: "3072"])
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.manifest(layers: [Self.vmConfigLayer, noDigest, Self.nvramLayer]))
    }
  }

  // MARK: - Semantic rules C2–C8

  @Test func c2RefusesADeclaredDiskSizeThatDisagreesWithTheChunks() throws {
    let error = #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(annotations: Self.annotations(diskSize: 4096)))
    }
    #expect(error?.message.contains("4096") == true)
    // Absent is fine: the chunks are the authority.
    #expect(try Self.parse(Self.flat(annotations: Self.annotations(diskSize: nil))).diskVirtualSize == 3072)
  }

  @Test func c3RefusesAnythingButArm64InBothConfigs() {
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), vmConfig: TartFixtures.vmConfig(arch: "amd64"))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), ociConfig: TartFixtures.ociConfig(architecture: "amd64"))
    }
  }

  @Test func c4RefusesANonRawDiskInEitherConfig() {
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), vmConfig: TartFixtures.vmConfig(diskFormat: "asif"))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), ociConfig: TartFixtures.ociConfig(diskFormat: "asif"))
    }
    // An absent label is not a claim of anything else.
    #expect(throws: Never.self) {
      try Self.parse(Self.flat(), ociConfig: TartFixtures.ociConfig(diskFormat: nil))
    }
  }

  @Test func c5RefusesTwoConfigsThatDisagreeAboutTheGuestOS() {
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), ociConfig: TartFixtures.ociConfig(os: "darwin"))
    }
  }

  @Test func c6RequiresABase64HardwareModelForDarwin() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.flat(), vmConfig: TartFixtures.vmConfig(os: "darwin"),
        ociConfig: TartFixtures.ociConfig(os: "darwin"))
    }
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.flat(), vmConfig: TartFixtures.vmConfig(os: "darwin", hardwareModel: "not base64!!"),
        ociConfig: TartFixtures.ociConfig(os: "darwin"))
    }
  }

  @Test func c7RefusesALinuxConfigCarryingAMacOSHardwareModel() {
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.flat(), vmConfig: TartFixtures.vmConfig(hardwareModel: TartFixtures.hardwareModel))
    }
  }

  @Test func c8RefusesAConfigSchemaVersionOtherThanOne() {
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat(), vmConfig: TartFixtures.vmConfig(version: 2))
    }
  }

  // MARK: - Limits

  @Test func aDiskLargerThanTheLimitIsRefusedBeforeAnythingIsFetched() {
    let huge: UInt64 = ArtifactLimits.default.maxVirtualDiskBytes + 1
    #expect(throws: RegistryError.self) {
      try Self.parse(Self.flat([huge], annotations: Self.annotations(diskSize: huge)))
    }
  }

  @Test func anOversizedNVRAMLayerIsRefused() {
    let oversized = Self.layer(
      TartMediaType.nvram, "2", size: ArtifactLimits.default.maxNVRAMBytes + 1)
    #expect(throws: RegistryError.self) {
      try Self.parse(
        Self.manifest(layers: [Self.vmConfigLayer] + Self.chunks() + [oversized]))
    }
  }
}
