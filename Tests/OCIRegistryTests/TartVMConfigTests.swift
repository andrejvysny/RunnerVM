import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

/// Config blobs shaped exactly the way tart writes them, so the importer is tested against the
/// wire format rather than against RunnerVM's idea of it.
enum TartFixtures {
  /// Verbatim from `ghcr.io/cirruslabs/ubuntu:latest` (tart 2.36), key order included.
  static let linuxConfigJSON = """
    {"cpuCountMin":4,"memorySizeMin":4294967296,"memorySize":4294967296,"cpuCount":4,\
    "diskFormat":"raw","display":{"height":768,"width":1024},"os":"linux","arch":"arm64",\
    "version":1,"macAddress":"6a:3e:f1:99:18:c1"}
    """

  static let hardwareModel = Data("fake-hardware-model".utf8).base64EncodedString()
  static let ecid = Data("fake-ecid".utf8).base64EncodedString()

  /// The same shape with tart's two macOS-only top-level keys added.
  static let darwinConfigJSON = """
    {"cpuCountMin":2,"memorySizeMin":4294967296,"memorySize":4294967296,"cpuCount":4,\
    "diskFormat":"raw","display":{"height":768,"width":1024},"os":"darwin","arch":"arm64",\
    "version":1,"macAddress":"6a:3e:f1:99:18:c1",\
    "hardwareModel":"\(hardwareModel)","ecid":"\(ecid)"}
    """

  /// `nil` omits the key entirely, which is how the "absent field" defaults are tested.
  static func vmConfig(
    version: Int? = 1, os: String? = "linux", arch: String? = "arm64", diskFormat: String? = "raw",
    cpuCountMin: Int = 4, cpuCount: Int = 4, memorySizeMin: UInt64 = 4_294_967_296,
    memorySize: UInt64 = 4_294_967_296, macAddress: String = "6a:3e:f1:99:18:c1",
    display: [String: Int]? = ["width": 1024, "height": 768], hardwareModel: String? = nil,
    ecid: String? = nil
  ) -> Data {
    var object: [String: Any] = [
      "cpuCountMin": cpuCountMin, "cpuCount": cpuCount,
      "memorySizeMin": memorySizeMin, "memorySize": memorySize, "macAddress": macAddress,
    ]
    object["version"] = version
    object["os"] = os
    object["arch"] = arch
    object["diskFormat"] = diskFormat
    object["display"] = display
    object["hardwareModel"] = hardwareModel
    object["ecid"] = ecid
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func ociConfig(
    os: String = "linux", architecture: String = "arm64", diskFormat: String? = "raw"
  ) -> Data {
    var object: [String: Any] = ["architecture": architecture, "os": os]
    if let diskFormat {
      object["config"] = ["Labels": [TartAnnotation.diskFormatLabel: diskFormat]]
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

struct TartVMConfigTests {
  @Test func decodesTheLinuxConfigTartActuallyPublishes() throws {
    let config = try TartVMConfig.decode(Data(TartFixtures.linuxConfigJSON.utf8))

    #expect(config.version == 1)
    #expect(config.os == .linux)
    #expect(config.arch == .arm64)
    #expect(config.cpuCountMin == 4)
    #expect(config.cpuCount == 4)
    #expect(config.memorySizeMin == 4_294_967_296)
    #expect(config.memorySize == 4_294_967_296)
    #expect(config.diskFormat == .raw)
    #expect(config.display?.width == 1024)
    #expect(config.display?.height == 768)
    #expect(config.display?.unit == nil)
    #expect(config.macAddress == "6a:3e:f1:99:18:c1")
    #expect(config.hardwareModel == nil)
    #expect(config.ecid == nil)
  }

  @Test func decodesTheDarwinConfigIncludingItsPlatformKeys() throws {
    let config = try TartVMConfig.decode(Data(TartFixtures.darwinConfigJSON.utf8))

    #expect(config.os == .darwin)
    #expect(config.cpuCountMin == 2)
    #expect(config.hardwareModel == TartFixtures.hardwareModel)
    #expect(config.ecid == TartFixtures.ecid)
  }

  /// tart's own decoder defaults these three, and a config written before those keys existed is
  /// still a valid macOS/arm64/raw VM.
  @Test func absentOSArchAndDiskFormatTakeTartsDefaults() throws {
    let config = try TartVMConfig.decode(
      TartFixtures.vmConfig(os: nil, arch: nil, diskFormat: nil, hardwareModel: TartFixtures.hardwareModel)
    )

    #expect(config.os == .darwin)
    #expect(config.arch == .arm64)
    #expect(config.diskFormat == .raw)
  }

  /// Deliberate deviation from tart, which maps anything unknown to `raw`: treating a format this
  /// build has never heard of as a raw disk would reassemble it into garbage.
  @Test func anUnknownDiskFormatIsRefusedRatherThanTreatedAsRaw() {
    #expect(throws: RegistryError.self) {
      try TartVMConfig.decode(TartFixtures.vmConfig(diskFormat: "qcow2"))
    }
  }

  @Test func aMalformedMACAddressIsRefused() {
    #expect(throws: RegistryError.self) {
      try TartVMConfig.decode(TartFixtures.vmConfig(macAddress: "not-a-mac"))
    }
    #expect(throws: RegistryError.self) {
      try TartVMConfig.decode(TartFixtures.vmConfig(macAddress: "6a:3e:f1:99:18"))
    }
    #expect(throws: RegistryError.self) {
      try TartVMConfig.decode(TartFixtures.vmConfig(macAddress: "6a:3e:f1:99:18:zz"))
    }
  }

  @Test func aMissingRequiredFieldIsARefusalNotADefault() {
    #expect(throws: RegistryError.self) {
      try TartVMConfig.decode(TartFixtures.vmConfig(version: nil))
    }
  }

  @Test func theOCIConfigCarriesTheDiskFormatLabel() throws {
    let config = try TartOCIConfig.decode(TartFixtures.ociConfig())
    #expect(config.architecture == "arm64")
    #expect(config.os == "linux")
    #expect(config.diskFormatLabel == "raw")

    let unlabelled = try TartOCIConfig.decode(TartFixtures.ociConfig(diskFormat: nil))
    #expect(unlabelled.diskFormatLabel == nil)
  }
}
