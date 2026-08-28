import DaemonAPI
import Foundation
import GuestControl
import ImageStore
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Phase D7: a managed macOS source becomes a locally sealed, cold-boot-qualified image, promoted
/// onto its alias -- driven through the real `ImageBuilder` ladder with only the host's edges faked
/// (the registry, `bootpd`, `provision-macos-tart.sh`, the guest agent).
@Suite struct MacOSProvisionTests {
  static let managedName = "macos-tahoe"

  /// A harness whose builder can run a macOS provisioning build end to end.
  private func withMacOSHarness(
    script: FakeProvisionScript? = nil,
    agent: FakeGuestAgent.Script = MacOSHostSimulator.readyAgent(),
    sshOpen: Bool = false,
    withholdLeases: Bool = false,
    tune: (@Sendable (inout ImageBuilder.Tuning) -> Void)? = nil,
    _ body: (
      BuildHarness, MacOSHostSimulator, FakeProvisionScript, ManagedImageSourceConfig,
      TartImagePublisher.Published
    ) async throws -> Void
  ) async throws {
    let registry = FakeRegistry()
    let reference = try registry.reference("cirruslabs/macos-tahoe-base", tag: "latest")
      .description
    var configuration = BuildHarness.configuration()
    let source = ManagedImageSourceConfig(
      name: Self.managedName, kind: .macosTart, source: reference,
      resources: ManagedImageSourceConfig.Resources(
        cpuCount: 2, memoryBytes: ByteSize.gibibytes(1).bytes))
    configuration.images.managed = [source]
    configuration.images.updates = ImageUpdatePolicyConfig(enabled: true, smokeTest: false)

    // A box, not a `var`: the tuning closure that reads it is `@Sendable` and outlives this frame.
    let simulator = SimulatorBox()
    let runner = script ?? FakeProvisionScript()
    let assetsBox = AssetsBox()
    let harness = try await BuildHarness(configuration: configuration, registry: registry) {
      tuning in
      tuning.processRunner = runner
      tuning.macosLeaseTimeout = .seconds(20)
      tuning.macosLeasePollInterval = .milliseconds(10)
      tuning.macosGuestStopTimeout = .seconds(10)
      tuning.macosGuestStopPollInterval = .milliseconds(10)
      tuning.macosQualifyTimeout = .seconds(20)
      tuning.sshProbe = { _, _, _ in sshOpen }
      tuning.dhcpLeases = { simulator.value?.leases() }
      tune?(&tuning)
    }
    let host = MacOSHostSimulator(
      paths: harness.paths, agentScript: agent, withholdLeases: withholdLeases)
    simulator.value = host
    host.start()
    // The fake script has to be able to tell the fake vmworker its guest halted itself, the way
    // the real guest does at the end of the lockdown.
    runner.attach(harness.base.launcher)

    do {
      let assets = try harness.macOSAssets()
      assetsBox.set(assets)
      var withAssets = configuration
      withAssets.build.macosProvisionScript = assets.script.path(percentEncoded: false)
      withAssets.build.macosGuestAgentPath = assets.agent.path(percentEncoded: false)
      await harness.builder.updateConfiguration(withAssets)
      let published = try harness.publishMacOSTart()
      try await body(harness, host, runner, source, published)
    } catch {
      await host.stop()
      await harness.cleanup()
      throw error
    }
    await host.stop()
    await harness.cleanup()
  }

  /// Carries the resolved asset paths out of the closure that made them.
  private final class AssetsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (script: URL, agent: URL)?
    func set(_ assets: (script: URL, agent: URL)) { lock.withLock { stored = assets } }
  }

  /// Lets the tuning closure -- built before the simulator exists -- reach it once it does.
  private final class SimulatorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MacOSHostSimulator?
    var value: MacOSHostSimulator? {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }

  // MARK: - Happy path

  @Test func aManagedMacOSSourceIsProvisionedSealedQualifiedAndPromoted() async throws {
    try await withMacOSHarness { harness, host, script, source, published in
      let updates = await harness.base.imageUpdates(
        configuration: harness.configuration,
        provisioning: MacOSProvisionLaunching(builder: harness.builder))
      await updates.updateConfiguration(harness.configuration)

      await updates.runCycle()

      // The track landed on the digest the build sealed, and the alias points at it.
      let track = try await harness.base.managedTrack(Self.managedName)
      #expect(track.state == .idle)
      #expect(track.lastError == nil)
      #expect(track.lastSourceDigest == published.manifestDigest.rawValue)
      let promoted = try #require(track.currentImageDigest)
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == promoted)
      #expect(track.candidateImageDigest == nil)

      // What was sealed: a macOS image that now has an agent and no SSH.
      let image = try await harness.base.images.get(reference: promoted.rawValue)
      let metadata = try #require(image.metadata)
      #expect(metadata.os == .macos)
      #expect(metadata.hasGuestAgent)
      #expect(metadata.capabilities.ssh == false)
      #expect(metadata.capabilities.docker == false)
      #expect(metadata.runnerVersion == "2.330.0")
      #expect(metadata.guestAgentVersion == "0.1.0-test")
      // The Tart lineage survives; the base is recorded as this image's parent.
      #expect(metadata.provenance?.imported?.format == "tart")
      #expect(metadata.macos?.hardwareModel.isEmpty == false)
      #expect(metadata.provenance?.parentImageDigest != nil)

      // The build row is a first-class `image_builds` row of the new kind.
      let rows = try await harness.buildRows.list(states: nil)
      let row = try #require(rows.first)
      #expect(row.kind == .macosProvision)
      #expect(row.managedName == Self.managedName)
      #expect(row.sourceDigest == published.manifestDigest.rawValue)
      #expect(row.state == .succeeded)
      #expect(row.imageDigest == promoted)
      #expect(row.fromReference == source.source)

      // The script was driven exactly per the fixed contract.
      let argv = try #require(script.invocations.first)
      #expect(argv.contains("--attach"))
      #expect(argv.contains("--result"))
      #expect(argv.contains("--agent-binary"))
      #expect(argv.contains("--work"))
      #expect(!argv.contains("--debug-ssh"))
      let attached = try #require(script.argument("--attach"))
      #expect(attached.hasPrefix("192.168.64."))

      // Two VMs came up: the provisioning one and the qualification clone, each with its own
      // directory and therefore its own machine identity.
      #expect(host.seen.count == 2)
      #expect(Set(host.seen).count == 2)

      // Nothing is left on disk, and the build's capacity is released.
      #expect(try await harness.builder.activeBuildReservations().isEmpty)
      #expect(
        await harness.base.metrics.counter(
          name: RunnerVMMetrics.imageUpdatePromotionsTotal, labels: ["kind": "macosTart"]) == 1)
    }
  }

  @Test func theSealedImageIsAliasedOnlyByThePromotionAndTheDirectoriesAreCleanedUp() async throws {
    try await withMacOSHarness { harness, _, _, _, _ in
      let id = try await harness.builder.startMacOSProvision(
        managed: harness.managedSource(
          reference: harness.configuration.images.managed[0].source, cpuCount: 2,
          memoryBytes: ByteSize.gibibytes(1).bytes))
      let row = try await harness.settle(id.rawValue)

      #expect(row.state == .succeeded)
      let digest = try #require(row.imageDigest)
      // `sealBuild(name: nil)`: the build alone never moves the managed alias.
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
      #expect(await harness.base.imageStore.exists(digest))
      let leftovers = (try? FileManager.default.contentsOfDirectory(
        at: harness.paths.buildsDir, includingPropertiesForKeys: nil))?
        .filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
      #expect(leftovers.isEmpty)
    }
  }

  // MARK: - Refusal matrix

  @Test(arguments: [
    MacOSProvisionResult(ok: false, error: "ssh never came up"),
    MacOSProvisionResult(ok: true, hardenProof: false, gracefulShutdown: true, ssh: false),
    MacOSProvisionResult(ok: true, hardenProof: true, gracefulShutdown: false, ssh: false),
    MacOSProvisionResult(ok: true, hardenProof: true, gracefulShutdown: true, ssh: true),
  ])
  func aResultThatDoesNotProveAHardenedGuestFailsTheBuild(
    result: MacOSProvisionResult
  ) async throws {
    try await withMacOSHarness(script: FakeProvisionScript(result: result)) {
      harness, _, _, source, _ in
      let id = try await harness.builder.startMacOSProvision(managed: source)
      let row = try await harness.settle(id.rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_MACOS_PROVISION_FAILED")
      #expect(row.imageDigest == nil)
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
    }
  }

  @Test func aScriptThatWritesNoResultFailsTheBuild() async throws {
    try await withMacOSHarness(script: FakeProvisionScript(exitCode: 1, writeResult: false)) {
      harness, _, _, source, _ in
      let row = try await harness.settle(
        try await harness.builder.startMacOSProvision(managed: source).rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_MACOS_PROVISION_FAILED")
      #expect(row.failureMessage?.contains("wrote no result") == true)
    }
  }

  @Test func aGuestThatNeverPowersItselfDownFailsTheBuild() async throws {
    try await withMacOSHarness(
      script: FakeProvisionScript(stopsGuest: false),
      tune: { $0.macosGuestStopTimeout = .milliseconds(200) }
    ) { harness, _, _, source, _ in
      let row = try await harness.settle(
        try await harness.builder.startMacOSProvision(managed: source).rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_MACOS_GUEST_DID_NOT_STOP")
      #expect(row.imageDigest == nil)
    }
  }

  @Test func aGuestThatNeverTakesADHCPLeaseFailsTheBuild() async throws {
    try await withMacOSHarness(
      withholdLeases: true, tune: { $0.macosLeaseTimeout = .milliseconds(200) }
    ) { harness, _, script, source, _ in
      let row = try await harness.settle(
        try await harness.builder.startMacOSProvision(managed: source).rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_AGENT_UNREACHABLE")
      #expect(row.failureMessage?.contains("BUILD_MACOS_LEASE_NOT_FOUND") == true)
      // Nothing was ever handed to the script: there was no address to hand it.
      #expect(script.invocations.isEmpty)
    }
  }

  @Test func aCandidateWhoseSelfTestFailsIsSealedButNeverPromoted() async throws {
    let failing = MacOSHostSimulator.readyAgent(
      selfTest: SelfTestResult(
        checks: [SelfTestCheck(name: "keychain", ok: false, detail: "no login keychain")]))
    try await withMacOSHarness(agent: failing) { harness, _, _, source, _ in
      let row = try await harness.settle(
        try await harness.builder.startMacOSProvision(managed: source).rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_MACOS_QUALIFICATION_FAILED")
      #expect(row.failureMessage?.contains("no login keychain") == true)
      // The seal happened -- the digest is on the row and in the store -- but the alias is not
      // moved, which is the invariant: an unqualified image is never promoted.
      let digest = try #require(row.imageDigest)
      #expect(await harness.base.imageStore.exists(digest))
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
    }
  }

  @Test func aCandidateStillAnsweringOnPort22IsNeverPromoted() async throws {
    try await withMacOSHarness(sshOpen: true) { harness, _, _, source, _ in
      let row = try await harness.settle(
        try await harness.builder.startMacOSProvision(managed: source).rawValue)

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_MACOS_QUALIFICATION_FAILED")
      #expect(row.failureMessage?.contains("still reachable") == true)
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
    }
  }

  @Test func aFailedProvisioningBuildLeavesTheManagedTrackFailedAndTheAliasUnmoved() async throws {
    try await withMacOSHarness(sshOpen: true) { harness, _, _, _, _ in
      let updates = await harness.base.imageUpdates(
        configuration: harness.configuration,
        provisioning: MacOSProvisionLaunching(builder: harness.builder))
      await updates.updateConfiguration(harness.configuration)

      await updates.runCycle()

      let track = try await harness.base.managedTrack(Self.managedName)
      #expect(track.state == .failed)
      #expect(track.currentImageDigest == nil)
      #expect(track.candidateImageDigest == nil)
      // Never written on a failure, so the next sweep still sees the move and retries.
      #expect(track.lastSourceDigest == nil)
      #expect(track.lastError?.contains("BUILD_MACOS_QUALIFICATION_FAILED") == true)
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
    }
  }

  // MARK: - Admission

  @Test func aProvisioningBuildIsChargedAgainstTheMacOSGuestLimit() async throws {
    try await withMacOSHarness { harness, _, _, source, _ in
      let mac = try await harness.base.importMacImage()
      for _ in 0..<HostConstants.macOSGuestLimit {
        try await harness.base.seedInstance(
          profile: "mac", state: .idle, digest: mac.record.digest)
      }

      let error = await #expect(throws: (any Error).self) {
        _ = try await harness.builder.startMacOSProvision(managed: source)
      }

      #expect((error as? any RunnerError)?.code == "SCHEDULER_MACOS_GUEST_LIMIT_REACHED")
      #expect(try await harness.buildRows.list(states: nil).isEmpty)
    }
  }

  @Test func aRunningProvisioningBuildReservesAMacOSSlot() async throws {
    let rows = [
      ImageBuildRecord(
        id: ImageBuildID.generate(), hostId: HostID(rawValue: "h"), state: .booting,
        recipePath: "/s", recipeSHA256: "sha256:x", contextPath: "/s", fromKind: .registry,
        fromReference: "ghcr.io/x/y:latest", cpuCount: 4, memoryBytes: 1 << 30,
        diskBytes: 1 << 30, diskReservationBytes: 1 << 30, timeoutMs: 1_000, buildPath: "/b",
        logPath: "/l", createdAt: .now, updatedAt: .now, kind: .macosProvision),
    ]

    let reservations = ImageBuilder.reservations(rows)

    #expect(reservations.count == 1)
    #expect(reservations[0].guestOS == .macos)
    #expect(reservations[0].isImageBuild)
  }

  // MARK: - Restart recovery

  @Test func theKindAndItsManagedNameSurviveARestart() async throws {
    try await withMacOSHarness { harness, _, _, source, published in
      let id = try await harness.builder.startMacOSProvision(
        managed: source, sourceDigest: published.manifestDigest.rawValue)
      _ = try await harness.settle(id.rawValue)

      let restarted = await harness.restartedBuilder()
      let row = try #require(try await harness.buildRows.get(id: id))
      #expect(row.kind == .macosProvision)
      #expect(row.managedName == Self.managedName)
      // A terminal row is not recovery's business.
      #expect(await restarted.recover() == (terminalized: 0, pending: 0))
    }
  }

  /// A crash between the store having the sealed content and the `images` row landing is replayed
  /// -- but *without* the alias, because the qualification that would justify promoting it never
  /// ran on this process.
  @Test func replayingAnInterruptedSealRegistersTheDigestWithoutMovingTheAlias() async throws {
    try await withMacOSHarness { harness, _, _, source, _ in
      let id = try await harness.builder.startMacOSProvision(managed: source)
      let finished = try await harness.settle(id.rawValue)
      let digest = try #require(finished.imageDigest)
      // Re-stage the same row as a crash would have left it: `sealing`, digest recorded, no
      // `images` row.
      try await harness.base.imageRows.unpin(
        ownerType: .managed, ownerId: Self.managedName, digest: digest)
      try await harness.base.imageRows.delete(digest: digest)
      let crashed = try await harness.seedBuildRow(
        state: .sealing, name: Self.managedName, imageDigest: digest, withDirectory: false,
        kind: .macosProvision)

      let restarted = await harness.restartedBuilder()
      _ = await restarted.recover()

      let row = try #require(try await harness.buildRows.get(id: crashed))
      #expect(row.state == .succeeded)
      #expect(try await harness.base.imageRows.get(digest: digest) != nil)
      #expect(try await harness.base.imageRows.alias(name: Self.managedName) == nil)
    }
  }
}
