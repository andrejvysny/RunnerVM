import Foundation
import GuestControl
import ImageStore
import OCIRegistry
import Persistence
import RunnerCore
import Synchronization
import Testing

@testable import Orchestration

/// Everything a `macosProvision` build needs from the world outside runnerd, faked: the macOS Tart
/// artifact in a registry, `bootpd`'s lease file, `provision-macos-tart.sh`, the darwin guest agent
/// binary, and the guest agent the qualification VM answers on.
///
/// Only the *host* edges are faked. The build's own ladder -- pull, clone, worker, transitions,
/// seal, teardown, recovery -- runs for real against the same `FakeWorkerLauncher` and `ImageStore`
/// every other builder test uses.
extension BuildHarness {
  /// Publishes a darwin Tart image (agentless, exactly as `ghcr.io/cirruslabs/macos-*-base` is).
  @discardableResult
  func publishMacOSTart(
    repository: String = "cirruslabs/macos-tahoe-base", tag: String = "latest",
    diskBytes: UInt64 = 8 << 20
  ) throws -> TartImagePublisher.Published {
    let directory = tree.root.appending(path: "tart-\(tag)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = directory.appending(path: "disk.img")
    FileManager.default.createFile(atPath: disk.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: disk)
    try handle.write(contentsOf: Data(repeating: 0x4D, count: 1 << 20))
    try handle.truncate(atOffset: diskBytes)
    try handle.close()
    let nvram = directory.appending(path: "nvram.bin")
    try Data(repeating: 0x5A, count: 64 << 10).write(to: nvram)
    return try TartImagePublisher.publish(
      into: base.registry, diskURL: disk, nvramURL: nvram,
      staging: directory.appending(path: "publish", directoryHint: .isDirectory),
      repository: repository, tag: tag, os: "darwin",
      chunkBytes: PublishedImage.chunkBytes, uploadTime: M2Harness.imageClock)
  }

  /// Writes stand-ins for the two files `provision-macos-tart.sh` resolution looks for, and returns
  /// a build config that points at them.
  func macOSAssets() throws -> (script: URL, agent: URL) {
    let root = tree.root.appending(path: "assets", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appending(path: MacOSProvisionAssets.scriptName)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    let agent = root.appending(path: "runnervm-guest-agent")
    try Data("darwin agent".utf8).write(to: agent)
    return (script, agent)
  }

  func managedSource(
    name: String = "macos-tahoe", reference: String, cpuCount: Int = 4,
    memoryBytes: UInt64 = ByteSize.gibibytes(2).bytes
  ) -> ManagedImageSourceConfig {
    ManagedImageSourceConfig(
      name: name, kind: .macosTart, source: reference,
      resources: ManagedImageSourceConfig.Resources(
        cpuCount: cpuCount, memoryBytes: memoryBytes))
  }
}

/// Stands in for the host around a macOS builder VM.
///
/// A single background poller does what the Mac would: it notices every VM directory the builder
/// materializes, reads the MAC out of its `spec.json`, hands that MAC an address in a synthetic
/// `dhcpd_leases`, and binds a guest agent where vmworker would publish its vsock bridge. That is
/// what makes both halves of the run reachable without the test having to know the ids and MACs
/// the builder generates.
final class MacOSHostSimulator: @unchecked Sendable {
  struct Guest: Sendable {
    var id: ImageBuildID
    var macAddress: String
    var address: String
  }

  private let paths: RunnerPaths
  private let agentScript: FakeGuestAgent.Script
  private let lock = NSLock()
  private var guests: [ImageBuildID: Guest] = [:]
  private var agents: [ImageBuildID: FakeGuestAgent] = [:]
  private var nextHost = 10
  /// Ids whose MAC is deliberately withheld from the lease file, so a build can be made to fail
  /// its `booting` stage.
  private let withholdLeases: Bool
  private var poller: Task<Void, Never>?

  init(
    paths: RunnerPaths, agentScript: FakeGuestAgent.Script = MacOSHostSimulator.readyAgent(),
    withholdLeases: Bool = false
  ) {
    self.paths = paths
    self.agentScript = agentScript
    self.withholdLeases = withholdLeases
  }

  /// A finished macOS image's agent: ready, `sw_vers` answers, `selfTest` passes.
  static func readyAgent(
    selfTest: SelfTestResult = SelfTestResult(
      checks: [SelfTestCheck(name: "keychain", ok: true)])
  ) -> FakeGuestAgent.Script {
    FakeGuestAgent.Script(
      selfTest: selfTest,
      execRoutes: [
        FakeGuestAgent.ExecRoute(match: "sw_vers", steps: [.stdout("26.0\n"), .exit(0)]),
      ])
  }

  func start() {
    poller = Task { [weak self] in
      while !Task.isCancelled {
        await self?.scan()
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  func stop() async {
    poller?.cancel()
    poller = nil
    let running = lock.withLock { Array(agents.values) }
    for agent in running { await agent.stop() }
    lock.withLock { agents.removeAll() }
  }

  /// `bootpd`'s file, as it would look with these guests on the shared network. Unpadded octets
  /// and the `1,` hardware-type prefix, exactly as the real one writes them.
  func leases() -> String {
    let known = lock.withLock { Array(guests.values) }
    guard !withholdLeases else { return "" }
    return known.map { guest in
      """
      {
      \tname=runnervm-\(RunnerPaths.shortID(guest.id))
      \tip_address=\(guest.address)
      \thw_address=1,\(DHCPLeaseResolver.normalize(guest.macAddress))
      \tidentifier=1,\(DHCPLeaseResolver.normalize(guest.macAddress))
      \tlease=0x68b1c2d3
      }
      """
    }.joined(separator: "\n")
  }

  /// The guest that came up for `id`, once the simulator has seen its `spec.json`.
  func guest(for id: ImageBuildID) -> Guest? { lock.withLock { guests[id] } }

  /// Every VM directory seen so far, provisioning and qualification alike, in discovery order.
  var seen: [ImageBuildID] {
    lock.withLock { guests.values.sorted { $0.address < $1.address }.map(\.id) }
  }

  private func scan() async {
    guard let directories = try? FileManager.default.contentsOfDirectory(
      at: paths.buildsDir, includingPropertiesForKeys: nil)
    else { return }
    for directory in directories where !directory.lastPathComponent.hasPrefix(".") {
      let id = ImageBuildID(rawValue: directory.lastPathComponent)
      let known = lock.withLock { guests[id] != nil }
      guard !known else { continue }
      let specURL = paths.buildVMDir(id).appending(path: VMInstanceLayout.specName)
      guard let data = FileManager.default.contents(
        atPath: specURL.path(percentEncoded: false)),
        let spec = try? JSONDecoder().decode(SpecPeek.self, from: data)
      else { continue }
      let address: String = lock.withLock {
        nextHost += 1
        let value = "192.168.64.\(nextHost)"
        guests[id] = Guest(id: id, macAddress: spec.macAddress, address: value)
        return value
      }
      _ = address
      await bindAgent(id)
    }
  }

  /// The qualification VM's guest agent. The provisioning VM never has one -- that is the point of
  /// the build -- but binding one there too is harmless: nothing ever dials it.
  private func bindAgent(_ id: ImageBuildID) async {
    try? FileManager.default.createDirectory(
      at: paths.buildSocketDir, withIntermediateDirectories: true)
    let agent = FakeGuestAgent(socketPath: paths.buildAgentSocket(id), script: agentScript)
    guard (try? await agent.start()) != nil else { return }
    lock.withLock { agents[id] = agent }
  }

  /// Only the field this simulator needs; `InstanceSpecFile` is internal to `Orchestration`.
  private struct SpecPeek: Decodable {
    var macAddress: String
  }
}

/// Stands in for `provision-macos-tart.sh`: records its argv, writes the `--result` JSON the real
/// script guarantees, and -- because the real guest halts itself when the lockdown is done -- tells
/// the fake vmworker its VM has stopped.
final class FakeProvisionScript: ProcessRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  private let result: MacOSProvisionResult
  private let exitCode: Int32
  private let writeResult: Bool
  /// Set after the harness exists, because the runner has to be built before it.
  private var launcher: FakeWorkerLauncher?
  /// Leaves the VM running, so the "the guest never powered itself down" path can be exercised.
  private let stopsGuest: Bool

  init(
    result: MacOSProvisionResult = MacOSProvisionResult(
      ok: true, runnerVersion: "2.330.0", guestAgentVersion: "0.1.0-test", hardenProof: true,
      gracefulShutdown: true, ssh: false),
    exitCode: Int32 = 0, writeResult: Bool = true, stopsGuest: Bool = true,
    launcher: FakeWorkerLauncher? = nil
  ) {
    self.result = result
    self.exitCode = exitCode
    self.writeResult = writeResult
    self.stopsGuest = stopsGuest
    self.launcher = launcher
  }

  func attach(_ launcher: FakeWorkerLauncher) { lock.withLock { self.launcher = launcher } }

  var invocations: [[String]] { lock.withLock { recorded } }

  func argument(_ flag: String) -> String? {
    guard let argv = invocations.last, let index = argv.firstIndex(of: flag),
          index + 1 < argv.count
    else { return nil }
    return argv[index + 1]
  }

  func run(
    _ executable: String, _ arguments: [String], timeout: Duration
  ) async throws -> ProcessResult {
    lock.withLock { recorded.append([executable] + arguments) }
    if writeResult, let index = arguments.firstIndex(of: "--result"), index + 1 < arguments.count {
      let url = URL(fileURLWithPath: arguments[index + 1])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(result).write(to: url)
    }
    let worker = lock.withLock { launcher }
    if stopsGuest, let worker, let work = value(of: "--work", in: arguments) {
      // `<buildsDir>/<id>/.provision` -> the build whose VM is being provisioned.
      let id = InstanceID(
        rawValue: URL(fileURLWithPath: work).deletingLastPathComponent().lastPathComponent)
      await worker.worker(for: id)?.emit(.stopped)
    }
    return ProcessResult(exitCode: exitCode, stdout: "provisioning finished\n")
  }

  private func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
