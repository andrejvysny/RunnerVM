import Foundation
import RunnerCore
import Testing
import Virtualization
@testable import VirtualizationCore

@Suite struct VMConfigurationBuilderTests {
  private func makeInstanceDir() throws -> VMRuntimePaths {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let paths = VMRuntimePaths(directory: dir)
    // 64 MiB sparse raw disk is enough for configuration validation.
    FileManager.default.createFile(atPath: paths.disk.path, contents: nil)
    let handle = try FileHandle(forWritingTo: paths.disk)
    try handle.truncate(atOffset: 64 << 20)
    try handle.close()
    try LinuxVMPlatform.createVariableStore(at: paths.nvram)
    return paths
  }

  private func spec() -> VMInstanceSpec {
    VMInstanceSpec(
      id: .generate(), imageDigest: ImageDigest(rawValue: "sha256:test"), os: .linux, cpuCount: 2,
      memoryBytes: 1 << 30, diskBytes: 64 << 20, macAddress: "02:00:00:aa:bb:cc")
  }

  @Test func linuxConfigurationIsHeadlessAndMinimal() throws {
    let paths = try makeInstanceDir()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let config = try VMConfigurationBuilder(spec: spec(), paths: paths).build(validate: false)

    #expect(config.bootLoader is VZEFIBootLoader)
    #expect(config.platform is VZGenericPlatformConfiguration)
    #expect(config.cpuCount == 2)
    #expect(config.memorySize == 1 << 30)
    #expect(config.graphicsDevices.isEmpty)
    #expect(config.audioDevices.isEmpty)
    #expect(config.keyboards.isEmpty)
    #expect(config.pointingDevices.isEmpty)
    #expect(config.directorySharingDevices.isEmpty)
    #expect(config.consoleDevices.isEmpty)
    #expect(config.networkDevices.count == 1)
    #expect(config.networkDevices[0].attachment is VZNATNetworkDeviceAttachment)
    #expect(config.networkDevices[0].macAddress.string == "02:00:00:aa:bb:cc")
    #expect(config.storageDevices.count == 1)
    #expect(config.entropyDevices.count == 1)
    #expect(config.socketDevices.count == 1)
    #expect(config.serialPorts.count == 1)
    #expect(FileManager.default.fileExists(atPath: paths.serialLog.path))
  }

  @Test func seedDiskIsAttachedReadOnly() throws {
    let paths = try makeInstanceDir()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    FileManager.default.createFile(atPath: paths.seedDisk.path, contents: Data(count: 1 << 20))
    let config = try VMConfigurationBuilder(spec: spec(), paths: paths, readOnlyDisks: [paths.seedDisk]).build(validate: false)
    #expect(config.storageDevices.count == 2)
    let seed = try #require(config.storageDevices[1].attachment as? VZDiskImageStorageDeviceAttachment)
    #expect(seed.isReadOnly)
  }

  @Test func rejectsInvalidMAC() throws {
    let paths = try makeInstanceDir()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    var bad = spec()
    bad.macAddress = "nope"
    #expect(throws: VMConfigurationError.self) { try VMConfigurationBuilder(spec: bad, paths: paths).build(validate: false) }
  }
}
