import Foundation
import RunnerCore
import Testing
import Virtualization

@testable import VirtualizationCore

/// The macOS half of `VMConfigurationBuilder`.
///
/// Everything here runs on an unsigned build: decoding a hardware model, minting a machine
/// identifier and constructing a `VZMacAuxiliaryStorage` are pure data operations. Only
/// `VZVirtualMachineConfiguration.validate()` and starting a VM need the virtualization
/// entitlement, so every test builds with `validate: false`.
@Suite struct MacOSVMPlatformTests {
  /// A test host that cannot run the fixture model (Intel, or a macOS that retired it) skips the
  /// cases that need a *usable* model; the decode-failure cases below never get that far and run
  /// everywhere.
  private static var hostSupportsFixture: Bool { MacOSFixtures.hostSupportsFixture }

  // MARK: - Hardware model decoding

  @Test func rejectsAHardwareModelThatIsNotBase64() throws {
    let error = #expect(throws: VMError.self) {
      try MacOSVMPlatform.hardwareModel(fromBase64: "not base64!")
    }
    #expect(try #require(error).code == "VM_MACOS_HARDWARE_MODEL_INVALID")
  }

  @Test func rejectsBase64ThatIsNotAHardwareModel() throws {
    let error = #expect(throws: VMError.self) {
      try MacOSVMPlatform.hardwareModel(fromBase64: Data("junk".utf8).base64EncodedString())
    }
    #expect(try #require(error).code == "VM_MACOS_HARDWARE_MODEL_INVALID")
  }

  /// A decodable model no host can run is a different problem from a corrupt one: the image is
  /// fine, this host just cannot boot it.
  @Test func rejectsADecodableModelThisHostCannotRun() throws {
    let error = #expect(throws: VMError.self) {
      try MacOSVMPlatform.hardwareModel(fromBase64: MacOSFixtures.unsupportedHardwareModel)
    }
    #expect(try #require(error).code == "VM_MACOS_HARDWARE_MODEL_UNSUPPORTED")
  }

  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func acceptsASupportedHardwareModel() throws {
    let model = try MacOSVMPlatform.hardwareModel(fromBase64: MacOSFixtures.supportedHardwareModel)
    #expect(model.dataRepresentation == Data(base64Encoded: MacOSFixtures.supportedHardwareModel))
    #expect(model.isSupported)
  }

  // MARK: - Whole configuration

  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func macOSConfigurationCarriesTheImageModelAndTheInstanceIdentity() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    let identifier = try MacOSMachineIdentity.create(at: paths.machineIdentifier)

    let config = try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)

    #expect(config.bootLoader is VZMacOSBootLoader)
    let platform = try #require(config.platform as? VZMacPlatformConfiguration)
    #expect(
      platform.hardwareModel.dataRepresentation
        == Data(base64Encoded: MacOSFixtures.supportedHardwareModel))
    #expect(platform.machineIdentifier.dataRepresentation == identifier.dataRepresentation)
    #expect(platform.auxiliaryStorage?.url == paths.nvram)
    #expect(config.cpuCount == 4)
    #expect(config.memorySize == 4 << 30)
  }

  /// The guest needs a framebuffer; nothing ever renders it (no `VZVirtualMachineView` exists
  /// anywhere in RunnerVM), and no other desktop device comes along with it.
  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func macOSConfigurationHasExactlyOneDisplayAndNoOtherDesktopDevices() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    try MacOSMachineIdentity.create(at: paths.machineIdentifier)

    let config = try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)

    #expect(config.graphicsDevices.count == 1)
    let graphics = try #require(config.graphicsDevices[0] as? VZMacGraphicsDeviceConfiguration)
    #expect(graphics.displays.count == 1)
    #expect(graphics.displays[0].widthInPixels == 1920)
    #expect(graphics.displays[0].heightInPixels == 1080)
    #expect(graphics.displays[0].pixelsPerInch == 80)
    #expect(config.keyboards.isEmpty)
    #expect(config.pointingDevices.isEmpty)
    #expect(config.audioDevices.isEmpty)
    #expect(config.directorySharingDevices.isEmpty)
  }

  /// The guest-facing devices are the same ones a Linux instance gets: the runner talks over vsock
  /// and the boot is diagnosed from `serial.log`, whichever OS is inside.
  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func macOSConfigurationKeepsTheSameRunnerDevicesAsLinux() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    try MacOSMachineIdentity.create(at: paths.machineIdentifier)

    let config = try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)

    #expect(config.networkDevices.count == 1)
    #expect(config.networkDevices[0].attachment is VZNATNetworkDeviceAttachment)
    #expect(config.networkDevices[0].macAddress.string == "02:00:00:aa:bb:cc")
    #expect(config.storageDevices.count == 1)
    let root = try #require(
      config.storageDevices[0].attachment as? VZDiskImageStorageDeviceAttachment)
    #expect(root.cachingMode == .cached)
    #expect(config.socketDevices.count == 1)
    #expect(config.entropyDevices.count == 1)
    #expect(config.serialPorts.count == 1)
  }

  // MARK: - Missing instance state

  /// `os: macos` with no `macos` block is an image that was imported without a hardware model, not
  /// an unsupported guest OS.
  @Test func rejectsAMacOSSpecWithNoPlatformBlock() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    var spec = macSpec()
    spec.macos = nil

    let error = #expect(throws: VMError.self) {
      try VMConfigurationBuilder(spec: spec, paths: paths).build(validate: false)
    }
    #expect(try #require(error).code == "VM_MACOS_HARDWARE_MODEL_MISSING")
  }

  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func rejectsAnInstanceWhoseAuxiliaryStorageWasNeverCloned() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    try MacOSMachineIdentity.create(at: paths.machineIdentifier)
    try FileManager.default.removeItem(at: paths.nvram)

    let error = #expect(throws: VMError.self) {
      try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)
    }
    #expect(try #require(error).code == "VM_MACOS_AUXILIARY_STORAGE_MISSING")
  }

  /// vmworker mints the identifier before it builds a configuration, so a missing file here means
  /// the instance lost its identity -- minting a replacement would strand `nvram.bin`.
  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func rejectsAnInstanceWithNoMachineIdentifier() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }

    let error = #expect(throws: VMError.self) {
      try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)
    }
    #expect(try #require(error).code == "VM_MACOS_MACHINE_IDENTIFIER_INVALID")
  }

  @Test(.enabled(if: MacOSVMPlatformTests.hostSupportsFixture))
  func rejectsACorruptedMachineIdentifier() throws {
    let paths = try makeInstanceDir()
    defer { Scratch.remove(paths.directory) }
    try Data("not an ECID".utf8).write(to: paths.machineIdentifier)

    let error = #expect(throws: VMError.self) {
      try VMConfigurationBuilder(spec: macSpec(), paths: paths).build(validate: false)
    }
    #expect(try #require(error).code == "VM_MACOS_MACHINE_IDENTIFIER_INVALID")
  }

  // MARK: - Fixtures

  /// A sparse disk plus a stand-in `nvram.bin`: `VZMacAuxiliaryStorage(url:)` only records the URL,
  /// so the bytes are never parsed on this path and 64 KiB of zeros is enough to exist.
  private func makeInstanceDir() throws -> VMRuntimePaths {
    let paths = try VMRuntimePaths(directory: Scratch.makeDirectory("macos-platform"))
    FileManager.default.createFile(atPath: paths.disk.path, contents: nil)
    let handle = try FileHandle(forWritingTo: paths.disk)
    try handle.truncate(atOffset: 64 << 20)
    try handle.close()
    FileManager.default.createFile(atPath: paths.nvram.path, contents: Data(count: 64 << 10))
    return paths
  }

  private func macSpec() -> VMInstanceSpec {
    VMInstanceSpec(
      id: .generate(), imageDigest: ImageDigest(rawValue: "sha256:test"), os: .macos, cpuCount: 4,
      memoryBytes: 4 << 30, diskBytes: 64 << 20, macAddress: "02:00:00:aa:bb:cc",
      macos: MacOSInstancePlatformSpec(hardwareModel: MacOSFixtures.supportedHardwareModel))
  }
}
