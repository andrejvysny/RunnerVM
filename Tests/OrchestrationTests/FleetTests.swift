import DaemonAPI
import Foundation
import GuestControl
import Logging
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// `fleet.*` (`Proto/fleet.md`): pure rules first, then the daemon service against the harness.
@Suite struct FleetSupportTests {
  // 51-byte ed25519 blob: "ssh-ed25519" + 32 zero bytes.
  static let blob: String = {
    var bytes: [UInt8] = [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
    bytes += [UInt8](repeating: 7, count: 32)
    return Data(bytes).base64EncodedString()
  }()
  static let good = "ssh-ed25519 \(blob)"

  private func code(_ key: String) -> String? {
    do { try FleetSupport.validatePublicKey(key); return nil } catch {
      return (error as? FleetError)?.code
    }
  }

  @Test func acceptsWellFormedKeys() {
    #expect(code(Self.good) == nil)
    #expect(code(Self.good + " ci@runner-1.example_x") == nil)
  }

  @Test func rejectsEverythingElse() {
    let rejected = [
      Self.good + "\n", "\n" + Self.good, Self.good + "\n" + Self.good, Self.good + " " + Self.good,
      "ssh-rsa " + Self.blob, "ssh-ed25519", "ssh-ed25519 ", "",
      Self.good + " a;rm -rf /", Self.good + " $(id)", Self.good + " `id`", Self.good + " a b",
      "ssh-ed25519 \(Self.blob)'; id; '", "ssh-ed25519 \(Self.blob)\ttab", Self.good + "\r",
      Self.good + " " + String(repeating: "a", count: 65),
      "ssh-ed25519 " + String(repeating: "A", count: 600),
      // wrong blob length: 50 bytes
      "ssh-ed25519 " + Data(([UInt8](repeating: 0, count: 50))).base64EncodedString(),
      // right length, wrong embedded type name
      "ssh-ed25519 " + Data(
        [0, 0, 0, 11] + Array("ssh-ed25518".utf8) + [0, 0, 0, 32]
          + [UInt8](repeating: 1, count: 32)).base64EncodedString(),
    ]
    for key in rejected { #expect(code(key) == "FLEET_INVALID_PUBLIC_KEY", "\(key.debugDescription)") }
  }

  @Test func stateMappingFollowsTheContract() {
    let expected: [InstanceState: String] = [
      .planned: "creating", .preparing: "creating", .cloning: "creating",
      .startingWorker: "creating", .startingVM: "creating", .waitingForAgent: "creating",
      .idle: "running", .configuringRunner: "running", .runnerStarting: "running",
      .runnerOnline: "running", .busy: "running", .cleaning: "running",
      .stopping: "deleting", .deleting: "deleting",
      .stopped: "deleted", .interrupted: "deleted", .failed: "deleted", .orphaned: "deleted",
      .deleted: "deleted",
    ]
    for state in InstanceState.allCases { #expect(FleetSupport.state(for: state) == expected[state]) }
  }

  @Test func addressPrefersThePrimaryAndSkipsBridges() {
    #expect(FleetSupport.address(primary: "192.168.64.9", addresses: ["172.17.0.1"]) == "192.168.64.9")
    let all = ["127.0.0.1", "169.254.1.1", "172.17.0.1", "172.31.0.2", "fe80::1", "192.168.64.7"]
    #expect(FleetSupport.address(primary: nil, addresses: all) == "192.168.64.7")
    #expect(FleetSupport.address(primary: "garbage", addresses: all) == "192.168.64.7")
    #expect(FleetSupport.address(primary: nil, addresses: ["172.32.0.1"]) == "172.32.0.1")
    #expect(FleetSupport.address(primary: nil, addresses: ["127.0.0.1", "172.17.0.1"]) == nil)
  }

  @Test func theKeyIsASeparateArgvElement() {
    let argv = FleetSupport.installArgv(user: "runner", home: "/home/runner", key: Self.good)
    #expect(argv.count == 7)
    #expect(argv[0...1] == ["/bin/sh", "-c"])
    #expect(argv[3...] == ["rvm-fleet", "runner", "/home/runner", Self.good])
    #expect(!argv[2].contains(Self.blob))
  }
}

@Suite struct FleetServiceTests {
  private static func configuration(maxInstances: Int? = nil) -> RunnerConfiguration {
    var config = M2Harness.configuration()
    let resources = ResourceSpec(
      cpuCount: 2, memoryBytes: ByteSize.gibibytes(2).bytes, diskBytes: ByteSize.gibibytes(1).bytes)
    config.profiles.append(
      RunnerProfileConfig(
        name: "glab", scope: nil, provider: .gitlab, image: M2Harness.linuxImageName,
        guestOS: .linux, resources: resources, limits: ProfileLimits(maxInstances: maxInstances)))
    config.profiles.append(
      RunnerProfileConfig(
        name: "glabmac", scope: nil, provider: .gitlab, image: M2Harness.macImageName,
        guestOS: .macos,
        resources: ResourceSpec(
          cpuCount: 4, memoryBytes: ByteSize.gibibytes(2).bytes,
          diskBytes: ByteSize.gibibytes(1).bytes)))
    return config
  }

  private func code(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch {
      return (error as? any RunnerError)?.code ?? "\(error)"
    }
  }

  private func create(_ service: DaemonServiceImpl, lease: Int64 = 600_000) async throws -> String {
    try await service.fleetCreate(FleetCreateRequest(profile: "glab", leaseMs: lease)).id
  }

  @Test func createIsRefusedForAGitHubProfileAndBadLeases() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      #expect(await code { _ = try await service.fleetCreate(.init(profile: "linux", leaseMs: 600_000)) }
        == "FLEET_PROFILE_NOT_GITLAB")
      for lease: Int64 in [59_999, 86_400_001, 0, -5] {
        #expect(await code { _ = try await service.fleetCreate(.init(profile: "glab", leaseMs: lease)) }
          == "FLEET_LEASE_INVALID")
      }
      #expect(try await harness.instanceCount(profile: "glab") == 0)
    }
  }

  @Test func createStampsPurposeAndLease() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let before = Date()
      let response = try await service.fleetCreate(.init(profile: "glab", leaseMs: 600_000))
      let record = try await harness.record(InstanceID(rawValue: response.id))
      #expect(record.purpose == .fleet)
      let pinned = try #require(record.pinnedUntil?.date)
      #expect(abs(pinned.timeIntervalSince(before) - 600) < 5)
      #expect(RFC3339.string(from: pinned) == response.leaseUntil)
    }
  }

  @Test func genericCreateRefusesFleetAndGitLabRunnerPurpose() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      #expect(await code { _ = try await service.instanceCreate(.init(profile: "glab", purpose: "fleet")) }
        == "FLEET_USE_FLEET_API")
      #expect(await code { _ = try await service.instanceCreate(.init(profile: "glab")) }
        == "PROFILE_GITLAB_FLEET_ONLY")
      #expect(await code {
        _ = try await service.instanceCreate(.init(profile: "glab", purpose: "maintenance", ttlMs: 60_000))
      } == nil)
    }
  }

  @Test func aMacOSFleetImageWithoutSSHIsRefused() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importMacImage()
      #expect(await code { _ = try await harness.service().fleetCreate(.init(profile: "glabmac", leaseMs: 600_000)) }
        == "FLEET_IMAGE_NO_SSH")
      #expect(try await harness.instanceCount(profile: "glabmac") == 0)
    }
  }

  @Test func aTickNeverTouchesAFleetInstanceEvenWithoutDemand() async throws {
    let config = Self.configuration()
    try await withHarness(configuration: config) { harness in
      try await harness.importLinuxImage()
      let id = InstanceID(rawValue: try await create(harness.service()))
      let agent = try await harness.startGuestAgent(for: id)
      try await harness.awaitInstance(id, state: .idle)
      let manual = ManualDemandProvider()
      let orchestrator = await harness.orchestrator(demand: manual, configuration: config)
      for _ in 0..<3 {
        await orchestrator.tick()
        await orchestrator.drainStarts()
      }
      #expect(try await harness.record(id).state == .idle)
      #expect(try await harness.runners.list().isEmpty)
      await agent.stop()
    }
  }

  @Test func theReaperDeletesAnExpiredLeaseAndKeepsARenewedOne() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let expired = try await create(service)
      let renewed = try await create(service)
      let later = Date().addingTimeInterval(1_000)
      _ = try await service.fleetRenew(.init(ids: [renewed], leaseMs: 3_600_000))
      let reaper = MaintenanceInstanceReaper(
        instances: harness.instanceRows, manager: harness.instances, events: harness.events,
        now: { later }, logger: Logger(label: "test"))
      #expect(try await reaper.run(firstTick: false).swept == 1)
      #expect(try await harness.record(InstanceID(rawValue: expired)).state == .deleted)
      #expect(try await harness.record(InstanceID(rawValue: renewed)).state != .deleted)
    }
  }

  @Test func renewSkipsDeletedUnknownAndNonFleetInstances() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let live = try await create(service)
      let gone = try await create(service)
      _ = try await service.fleetDelete(.init(id: gone))
      let runner = try await harness.instances.create(profileName: "linux")
      let response = try await service.fleetRenew(
        .init(ids: [live, gone, "nope", runner.id.rawValue, live], leaseMs: 120_000))
      #expect(response.renewed == [live])
      #expect(await code { _ = try await service.fleetRenew(.init(ids: [live], leaseMs: 1)) }
        == "FLEET_LEASE_INVALID")
    }
  }

  @Test func deleteIsIdempotentAndRefusesNonFleetInstances() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let id = try await create(service)
      #expect(try await service.fleetDelete(.init(id: id)).accepted)
      #expect(try await harness.record(InstanceID(rawValue: id)).state == .deleted)
      #expect(try await service.fleetDelete(.init(id: id)).accepted)
      #expect(try await service.fleetDelete(.init(id: "unknown")).accepted)
      let runner = try await harness.instances.create(profileName: "linux")
      #expect(await code { _ = try await service.fleetDelete(.init(id: runner.id.rawValue)) }
        == "FLEET_PROFILE_NOT_GITLAB")
      let pinned = try await harness.instances.create(
        profileName: "glab",
        options: InstanceCreateOptions(purpose: .maintenance, pinnedUntil: Date().addingTimeInterval(600)))
      #expect(await code { _ = try await service.fleetDelete(.init(id: pinned.id.rawValue)) }
        == "FLEET_INSTANCE_NOT_FLEET")
    }
  }

  @Test func listMapsStatesAndHidesOldDeletedRows() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let live = try await create(service)
      let gone = try await create(service)
      _ = try await service.fleetDelete(.init(id: gone))
      let listed = try await service.fleetList(.init(profile: "glab")).instances
      #expect(listed.map(\.id).sorted() == [live, gone].sorted())
      #expect(listed.first { $0.id == gone }?.state == "deleted")
      #expect(listed.first { $0.id == live }?.leaseUntil != nil)
      #expect(await code { _ = try await service.fleetList(.init(profile: "linux")) }
        == "FLEET_PROFILE_NOT_GITLAB")
    }
  }

  @Test func infoRespectsTheProfileMaxInstances() async throws {
    try await withHarness(configuration: Self.configuration(maxInstances: 2)) { harness in
      let service = harness.service()
      let info = try await service.fleetInfo(.init(profile: "glab"))
      #expect(info.maxInstances == 2)
      #expect(info.guestOS == "linux" && info.arch == "arm64" && info.sshUser == "runner")
    }
  }

  @Test func connectRefusesBeforeIdleAndInstallsTheKeyAsOneArgvElement() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let id = InstanceID(rawValue: try await create(service))
      #expect(await code {
        _ = try await service.fleetConnect(.init(id: id.rawValue, publicKey: FleetSupportTests.good))
      } == "FLEET_INSTANCE_NOT_READY")

      var script = FakeGuestAgent.Script()
      script.exec = [.exit(0)]
      script.info = GuestInfo(
        ipAddresses: ["172.17.0.1", "192.168.64.7"], uptimeSec: 1, kernel: "k",
        primaryAddress: "192.168.64.8")
      let agent = try await harness.startGuestAgent(for: id, script: script)
      try await harness.awaitInstance(id, state: .idle)

      #expect(await code {
        _ = try await service.fleetConnect(.init(id: id.rawValue, publicKey: "ssh-rsa AAAA"))
      } == "FLEET_INVALID_PUBLIC_KEY")
      let response = try await service.fleetConnect(
        .init(id: id.rawValue, publicKey: FleetSupportTests.good))
      #expect(response.address == "192.168.64.8")
      #expect(response.port == 22 && response.user == "runner")
      #expect(response.guestOS == "linux" && response.arch == "arm64")
      #expect(await agent.lastExec()?.argv == FleetSupport.installArgv(
        user: "runner", home: "/home/runner", key: FleetSupportTests.good))
      await agent.stop()
    }
  }

  @Test func connectReportsAFailedInstallWithoutTheKey() async throws {
    try await withHarness(configuration: Self.configuration()) { harness in
      try await harness.importLinuxImage()
      let service = harness.service()
      let id = InstanceID(rawValue: try await create(service))
      var script = FakeGuestAgent.Script()
      script.exec = [.exit(3)]
      let agent = try await harness.startGuestAgent(for: id, script: script)
      try await harness.awaitInstance(id, state: .idle)
      do {
        _ = try await service.fleetConnect(.init(id: id.rawValue, publicKey: FleetSupportTests.good))
        Issue.record("expected FLEET_KEY_INSTALL_FAILED")
      } catch let error as FleetError {
        #expect(error.code == "FLEET_KEY_INSTALL_FAILED")
        #expect(error.message.contains("3"))
        #expect(!error.message.contains(FleetSupportTests.blob))
      }
      await agent.stop()
    }
  }
}
