import Foundation
import RunnerCore
import Testing
import Virtualization

@testable import VirtualizationCore

/// `machine-identifier.bin` is the guest's ECID: macOS binds activation state and the auxiliary
/// storage's boot policy to it, so the identifier minted for an instance has to come back
/// byte-identical on every later boot and must never be shared with a second instance.
///
/// Minting and re-decoding an identifier need no virtualization entitlement, so all of this runs on
/// an unsigned test build.
@Suite struct MacOSMachineIdentityTests {
  private func scratch() throws -> URL { try Scratch.makeDirectory("machine-id") }

  @Test func createWritesAPrivateFileAndLeavesNoTemporaryBehind() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).machineIdentifier

    let identifier = try MacOSMachineIdentity.create(at: url)

    #expect(FileManager.default.fileExists(atPath: url.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(try Data(contentsOf: url) == identifier.dataRepresentation)
    let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(children == ["machine-identifier.bin"])
  }

  @Test func loadReturnsTheIdentifierThatWasWritten() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).machineIdentifier
    let created = try MacOSMachineIdentity.create(at: url)

    let loaded = try MacOSMachineIdentity.load(at: url)

    #expect(loaded.dataRepresentation == created.dataRepresentation)
  }

  /// The restart contract: a second worker for the same instance directory reuses the identity
  /// rather than minting a new machine.
  @Test func loadOrCreateMintsOnceAndReusesAfterwards() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).machineIdentifier

    let first = try MacOSMachineIdentity.loadOrCreate(at: url)
    let second = try MacOSMachineIdentity.loadOrCreate(at: url)

    #expect(first.created)
    #expect(!second.created)
    #expect(first.identifier.dataRepresentation == second.identifier.dataRepresentation)
  }

  @Test func twoInstancesNeverShareAnIdentity() throws {
    let first = try scratch()
    let second = try scratch()
    defer {
      Scratch.remove(first)
      Scratch.remove(second)
    }

    let one = try MacOSMachineIdentity.create(at: VMRuntimePaths(directory: first).machineIdentifier)
    let two = try MacOSMachineIdentity.create(at: VMRuntimePaths(directory: second).machineIdentifier)

    #expect(one.dataRepresentation != two.dataRepresentation)
  }

  @Test func aCorruptedFileIsATypedRefusalNotACrash() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).machineIdentifier
    try Data("junk".utf8).write(to: url)

    let error = #expect(throws: VMError.self) {
      try MacOSMachineIdentity.loadOrCreate(at: url)
    }

    #expect(error?.code == "VM_MACOS_MACHINE_IDENTIFIER_INVALID")
    #expect(error?.retryable == false)
  }

  @Test func theRuntimePathIsTheNameTheWorkerContractDocuments() {
    let paths = VMRuntimePaths(directory: URL(fileURLWithPath: "/tmp"))
    #expect(paths.machineIdentifier.lastPathComponent == "machine-identifier.bin")
  }
}
