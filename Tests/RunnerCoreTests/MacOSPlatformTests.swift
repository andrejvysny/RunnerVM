import Foundation
import Testing

@testable import RunnerCore

/// The macOS platform block of `metadata.json` and its `spec.json` counterpart. Both gained sizing
/// floors in M8.1, so both have to keep decoding files sealed before those fields existed.
@Suite struct MacOSPlatformTests {
  private static let hardwareModel = Data("fake-hardware-model".utf8).base64EncodedString()

  @Test func theMinimumsSurviveAnEncodeDecodeRoundTrip() throws {
    let platform = ImageMetadata.MacOSPlatform(
      hardwareModel: Self.hardwareModel, sourceVersion: "26.0",
      minimumCPUCount: 6, minimumMemoryBytes: ByteSize.gibibytes(8).bytes)

    let encoded = try JSONEncoder().encode(platform)
    let decoded = try JSONDecoder().decode(ImageMetadata.MacOSPlatform.self, from: encoded)

    #expect(decoded == platform)
    #expect(decoded.minimumCPUCount == 6)
    #expect(decoded.minimumMemoryBytes == ByteSize.gibibytes(8).bytes)
  }

  /// Every macOS image sealed before M8.1 has only these two keys.
  @Test func metadataSealedWithoutTheMinimumsStillDecodes() throws {
    let json = #"{"hardwareModel":"\#(Self.hardwareModel)","sourceVersion":"15.4"}"#

    let decoded = try JSONDecoder().decode(
      ImageMetadata.MacOSPlatform.self, from: Data(json.utf8))

    #expect(decoded.hardwareModel == Self.hardwareModel)
    #expect(decoded.sourceVersion == "15.4")
    #expect(decoded.minimumCPUCount == nil)
    #expect(decoded.minimumMemoryBytes == nil)
  }

  /// A Linux image's metadata must not grow macOS keys just because the type did.
  @Test func absentMinimumsAreOmittedFromTheEncoding() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(ImageMetadata.MacOSPlatform(hardwareModel: Self.hardwareModel))

    #expect(String(decoding: bytes, as: UTF8.self) == #"{"hardwareModel":"\#(Self.hardwareModel)"}"#)
  }

  @Test func theInstanceSpecCopiesEveryPlatformField() {
    let platform = ImageMetadata.MacOSPlatform(
      hardwareModel: Self.hardwareModel, sourceVersion: "26.0",
      minimumCPUCount: 4, minimumMemoryBytes: ByteSize.gibibytes(4).bytes)

    let spec = MacOSInstancePlatformSpec(platform)

    #expect(spec.hardwareModel == platform.hardwareModel)
    #expect(spec.sourceVersion == platform.sourceVersion)
    #expect(spec.minimumCPUCount == platform.minimumCPUCount)
    #expect(spec.minimumMemoryBytes == platform.minimumMemoryBytes)
  }

  @Test func theInstanceSpecRoundTripsThroughJSON() throws {
    let spec = MacOSInstancePlatformSpec(
      hardwareModel: Self.hardwareModel, minimumCPUCount: 2)

    let decoded = try JSONDecoder().decode(
      MacOSInstancePlatformSpec.self, from: try JSONEncoder().encode(spec))

    #expect(decoded == spec)
    #expect(decoded.sourceVersion == nil)
    #expect(decoded.minimumMemoryBytes == nil)
  }
}
