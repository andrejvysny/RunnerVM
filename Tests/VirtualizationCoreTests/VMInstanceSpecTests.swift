import Foundation
import RunnerCore
import Testing

@testable import VirtualizationCore

/// `spec.json` is the only thing runnerd hands vmworker, and M8.1 added an optional `macos` block
/// to it. A Linux spec must keep the exact key set it had before, byte for byte.
@Suite struct VMInstanceSpecTests {
  private func spec(macos: MacOSInstancePlatformSpec? = nil) -> VMInstanceSpec {
    VMInstanceSpec(
      id: InstanceID(rawValue: "11111111-2222-3333-4444-555555555555"),
      imageDigest: ImageDigest(rawValue: "sha256:test"), os: macos == nil ? .linux : .macos,
      cpuCount: 4, memoryBytes: 1 << 31, diskBytes: 64 << 20, macAddress: "02:00:00:aa:bb:cc",
      macos: macos)
  }

  private func keys(of spec: VMInstanceSpec) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: try spec.encoded())
    return Set((object as? [String: Any])?.keys ?? [:].keys)
  }

  @Test func aLinuxSpecCarriesNoMacOSBlock() throws {
    #expect(try !keys(of: spec()).contains("macos"))
    #expect(!String(decoding: try spec().encoded(), as: UTF8.self).contains("macos"))
  }

  @Test func aMacOSSpecEncodesTheWholePlatformBlockAndRoundTrips() throws {
    let platform = MacOSInstancePlatformSpec(
      hardwareModel: "aGFyZHdhcmU=", sourceVersion: "26.0", minimumCPUCount: 4,
      minimumMemoryBytes: 1 << 31)
    let encoded = try spec(macos: platform).encoded()

    #expect(try keys(of: spec(macos: platform)).contains("macos"))
    let decoded = try VMInstanceSpec.decoder().decode(VMInstanceSpec.self, from: encoded)
    #expect(decoded == spec(macos: platform))
    #expect(decoded.macos == platform)
  }
}
