import Foundation
import RunnerCore
import Testing
import Virtualization
@testable import VirtualizationCore

@Suite struct VMRuntimeStateTests {
  /// The whole table, so a framework state can never silently fall through to a default.
  @Test func mapsEveryFrameworkState() {
    let table: [(VZVirtualMachine.State, VMRunState)] = [
      (.stopped, .stopped), (.starting, .starting), (.running, .running),
      (.pausing, .running), (.paused, .running), (.resuming, .running),
      (.stopping, .stopping), (.error, .error),
      (.saving, .starting), (.restoring, .starting),
    ]
    for (input, expected) in table {
      #expect(VMRuntime.map(input) == expected, "state \(input.rawValue)")
    }
  }

  /// vmworker translates `VMRunState` into `WorkerProtocol.WorkerVMState` by raw value equality;
  /// the two targets cannot import each other, so the contract is asserted here.
  @Test func rawValuesMatchTheWireVocabulary() {
    #expect(VMRunState.allCases.map(\.rawValue) == ["stopped", "starting", "running", "stopping", "error"])
  }
}

@Suite struct VMInstanceSpecCodingTests {
  private func spec(hardDeadline: Date? = nil) -> VMInstanceSpec {
    VMInstanceSpec(
      id: InstanceID(rawValue: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"),
      imageDigest: ImageDigest(rawValue: "sha256:abc"), os: .linux, cpuCount: 2,
      memoryBytes: 2 << 30, diskBytes: 64 << 30, macAddress: "02:00:00:aa:bb:cc",
      hardDeadline: hardDeadline)
  }

  @Test func roundTripsHardDeadlineAsRFC3339() throws {
    let deadline = Date(timeIntervalSince1970: 1_700_000_000)
    let data = try spec(hardDeadline: deadline).encoded()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"hardDeadline\":\"2023-11-14T22:13:20Z\""))
    let decoded = try VMInstanceSpec.decoder().decode(VMInstanceSpec.self, from: data)
    #expect(decoded == spec(hardDeadline: deadline))
  }

  @Test func hardDeadlineIsOptional() throws {
    let data = try spec().encoded()
    #expect(!String(decoding: data, as: UTF8.self).contains("hardDeadline"))
    #expect(try VMInstanceSpec.decoder().decode(VMInstanceSpec.self, from: data) == spec())
  }

  @Test func digestIsStableForTheSameBytesAndChangesWithThem() throws {
    let directory = try Scratch.makeDirectory("digest")
    defer { Scratch.remove(directory) }
    let url = directory.appendingPathComponent("spec.json")
    try spec().encoded().write(to: url)
    let first = try SpecDigest.sha256Hex(ofFileAt: url)
    let second = try SpecDigest.sha256Hex(ofFileAt: url)
    #expect(first == second)
    #expect(first.count == 64)
    #expect(first == SpecDigest.sha256Hex(of: try Data(contentsOf: url)))

    try spec(hardDeadline: Date(timeIntervalSince1970: 1)).encoded().write(to: url)
    #expect(try SpecDigest.sha256Hex(ofFileAt: url) != first)
  }

  @Test func knownVectorMatchesShasum() {
    #expect(
      SpecDigest.sha256Hex(of: Data("runnervm".utf8))
        == "ab308bc1b6974861f4ea6884e1d2544046569d49bd2fd86d47d62b0a8558089a")
  }

  @Test func loadsFromDiskThroughTheCanonicalCodec() throws {
    let directory = try Scratch.makeDirectory("load")
    defer { Scratch.remove(directory) }
    let url = directory.appendingPathComponent("spec.json")
    try spec(hardDeadline: Date(timeIntervalSince1970: 1_700_000_000)).encoded().write(to: url)
    let loaded = try VMInstanceSpec.load(contentsOf: url)
    #expect(loaded.hardDeadline == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(VMRuntimePaths(directory: directory).workerLock.lastPathComponent == "worker.lock")
  }
}
