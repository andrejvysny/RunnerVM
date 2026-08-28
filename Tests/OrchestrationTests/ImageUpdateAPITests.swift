import DaemonAPI
import Foundation
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Phase D6: which references become tracks, the `macosTart` half, and the three
/// `image.update.*` methods.
@Suite struct ImageUpdateAPITests {
  // MARK: - Track derivation

  /// The reference grammar the tracker accepts, stated once. A digest is never tracked (the
  /// operator already chose the bytes) and neither is a bare local name (there is no upstream).
  @Test func onlyRegistryReferencesCarryingATagAreTracked() {
    #expect(
      ImageUpdateService.trackedReference("ghcr.io/acme/runners/ubuntu-24:stable")
        == "ghcr.io/acme/runners/ubuntu-24:stable")
    #expect(ImageUpdateService.trackedReference("ghcr.io/acme/runners/ubuntu-24") == nil)
    #expect(ImageUpdateService.trackedReference("test-linux") == nil)
    #expect(ImageUpdateService.trackedReference("test-linux:v2") == nil)
    #expect(
      ImageUpdateService.trackedReference(
        "ghcr.io/acme/runners/ubuntu-24@sha256:" + String(repeating: "a", count: 64)) == nil)
    #expect(
      ImageUpdateService.trackedReference("sha256:" + String(repeating: "a", count: 64)) == nil)
  }

  @Test func aDigestPinnedOrLocalProfileImageProducesNoTrackRows() async throws {
    let pinned = "ghcr.io/acme/runners/ubuntu-24@sha256:" + String(repeating: "a", count: 64)
    let config = M2Harness.updateConfiguration(image: pinned)
    try await withHarness(configuration: config) { harness in
      _ = await harness.imageUpdates(configuration: config)
      // The harness's `mac` profile names a bare local image, so both profiles are untrackable.
      let tracked = try await harness.managedRows.list()
      #expect(tracked.isEmpty)
    }
  }

  /// A track whose source leaves the configuration is left in place, not deleted: the row still
  /// describes pins and retained digests that exist on this disk.
  @Test func aTrackWhoseSourceLeavesTheConfigurationIsKept() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let updates = await harness.imageUpdates(configuration: config)
      let derived = try await harness.managedRows.list()
      #expect(derived.map(\.name) == [reference])

      await updates.updateConfiguration(
        M2Harness.updateConfiguration(image: M2Harness.linuxImageName))

      let kept = try await harness.managedRows.list()
      #expect(kept.map(\.name) == [reference])
    }
  }

  /// Re-deriving a track only refreshes the columns the configuration owns.
  @Test func rederivingATrackPreservesEverythingTheCycleOwns() async throws {
    let source = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    let entry = ManagedImageSourceConfig(name: "macos-tahoe", kind: .macosTart, source: source)
    let config = M2Harness.updateConfiguration(
      image: M2Harness.linuxImageName, managed: [entry])
    try await withHarness(configuration: config) { harness in
      let updates = await harness.imageUpdates(configuration: config)
      var row = try await harness.managedTrack("macos-tahoe")
      row.lastSourceDigest = "sha256:" + String(repeating: "b", count: 64)
      row.lastCheckedAt = .now
      try await harness.managedRows.upsert(row)

      var changed = entry
      changed.autoUpdate = false
      await updates.updateConfiguration(
        M2Harness.updateConfiguration(image: M2Harness.linuxImageName, managed: [changed]))

      let after = try await harness.managedTrack("macos-tahoe")
      #expect(after.autoUpdate == false)
      #expect(after.lastSourceDigest == row.lastSourceDigest)
      #expect(after.lastCheckedAt != nil)
    }
  }

  // MARK: - macOS Tart sources

  /// With no provisioning launcher wired in -- the M1-M5 harness shape -- a Tart source is tracked
  /// and nothing else: no transfer, no build, no image row, and the row says why it stops there.
  ///
  /// `lastSourceDigest` deliberately stays `nil`: it is written at promotion and nowhere else, so
  /// the next sweep still sees the move and retries instead of believing it was handled.
  @Test func aMacOSTartSourceWithNoLauncherIsRecordedButNotActedOn() async throws {
    let registry = FakeRegistry()
    let source = try registry.reference("cirruslabs/macos-tahoe-base", tag: "latest").description
    let config = M2Harness.updateConfiguration(
      image: M2Harness.linuxImageName,
      managed: [
        ManagedImageSourceConfig(name: "macos-tahoe", kind: .macosTart, source: source),
      ])
    try await withHarness(configuration: config, registry: registry) { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "tart"),
        repository: "cirruslabs/macos-tahoe-base", tag: "latest", guestAgent: false)
      let updates = await harness.imageUpdates(configuration: config)

      await updates.runCycle()

      let track = try await harness.managedTrack("macos-tahoe")
      #expect(track.kind == .macosTart)
      #expect(track.state == .idle)
      #expect(track.lastSourceDigest == nil)
      #expect(track.lastCheckedAt != nil)
      #expect(track.currentImageDigest == nil)
      #expect(track.lastError == ImageUpdateService.provisioningPending)
      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(try await harness.imageRows.list(state: nil).isEmpty)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.imageUpdateChecksTotal, labels: ["kind": "macosTart"]) == 1)
    }
  }

  /// With a launcher wired, the moved digest becomes a provisioning run whose sealed, qualified
  /// candidate is promoted onto the managed alias -- the D7 shape, with the build itself faked.
  @Test func aMacOSTartSourceIsProvisionedAndPromotedOntoItsAlias() async throws {
    let registry = FakeRegistry()
    let source = try registry.reference("cirruslabs/macos-tahoe-base", tag: "latest").description
    let config = M2Harness.updateConfiguration(
      image: M2Harness.linuxImageName,
      managed: [
        ManagedImageSourceConfig(name: "macos-tahoe", kind: .macosTart, source: source),
      ])
    try await withHarness(configuration: config, registry: registry) { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "tart"),
        repository: "cirruslabs/macos-tahoe-base", tag: "latest", guestAgent: false)
      // What the provisioning build would have sealed: a real, locally stored macOS image.
      let sealed = try await harness.importMacImage()
      let launcher = RecordingProvisionLauncher(result: sealed.record.digest)
      let updates = await harness.imageUpdates(configuration: config, provisioning: launcher)

      await updates.runCycle()

      #expect(
        launcher.recorded
          == [
            RecordingProvisionLauncher.Call(
              name: "macos-tahoe", sourceDigest: published.manifestDigest.rawValue),
          ])
      let track = try await harness.managedTrack("macos-tahoe")
      #expect(track.state == .idle)
      #expect(track.currentImageDigest == sealed.record.digest)
      #expect(track.candidateImageDigest == nil)
      // Written at promotion, so the next sweep knows this exact upstream has been acted on.
      #expect(track.lastSourceDigest == published.manifestDigest.rawValue)
      #expect(track.lastError == nil)
      // The alias is what a macOS profile's `image: macos-tahoe` resolves through.
      #expect(try await harness.imageRows.alias(name: "macos-tahoe") == sealed.record.digest)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.imageUpdatePromotionsTotal, labels: ["kind": "macosTart"]) == 1)

      // A second sweep sees an unmoved digest and does nothing.
      await updates.runCycle()
      #expect(launcher.recorded.count == 1)
    }
  }

  /// A provisioning run that fails never repoints the alias, and the reason is on the row.
  @Test func aFailedProvisioningRunLeavesTheAliasAlone() async throws {
    let registry = FakeRegistry()
    let source = try registry.reference("cirruslabs/macos-tahoe-base", tag: "latest").description
    let config = M2Harness.updateConfiguration(
      image: M2Harness.linuxImageName,
      managed: [
        ManagedImageSourceConfig(name: "macos-tahoe", kind: .macosTart, source: source),
      ])
    try await withHarness(configuration: config, registry: registry) { harness in
      try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "tart"),
        repository: "cirruslabs/macos-tahoe-base", tag: "latest", guestAgent: false)
      let launcher = RecordingProvisionLauncher(failure: "SSH is still open in the sealed guest")
      let updates = await harness.imageUpdates(configuration: config, provisioning: launcher)

      await updates.runCycle()

      let track = try await harness.managedTrack("macos-tahoe")
      #expect(track.state == .failed)
      #expect(track.currentImageDigest == nil)
      #expect(track.lastSourceDigest == nil)
      #expect(track.lastError?.contains("SSH is still open") == true)
      #expect(try await harness.imageRows.alias(name: "macos-tahoe") == nil)
    }
  }

  @Test func aMacOSTartSourceWithAutoUpdateOffIsRecordedButNotHandedOn() async throws {
    let registry = FakeRegistry()
    let source = try registry.reference("cirruslabs/macos-tahoe-base", tag: "latest").description
    let config = M2Harness.updateConfiguration(
      image: M2Harness.linuxImageName,
      managed: [
        ManagedImageSourceConfig(
          name: "macos-tahoe", kind: .macosTart, source: source, autoUpdate: false),
      ])
    try await withHarness(configuration: config, registry: registry) { harness in
      try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "tart"),
        repository: "cirruslabs/macos-tahoe-base", tag: "latest", guestAgent: false)
      let sealed = try await harness.importMacImage()
      let launcher = RecordingProvisionLauncher(result: sealed.record.digest)
      let updates = await harness.imageUpdates(configuration: config, provisioning: launcher)

      // The scheduled sweep skips it entirely.
      await updates.runScheduledCycle()
      #expect(try await harness.managedTrack("macos-tahoe").lastCheckedAt == nil)

      // An explicit run is the operator asking for one, so it provisions and promotes.
      await updates.runCycle(only: "macos-tahoe")

      #expect(try await harness.managedTrack("macos-tahoe").lastSourceDigest != nil)
      #expect(launcher.provisioned == ["macos-tahoe"])
    }
  }

  // MARK: - RPC surface

  @Test func theThreeMethodsAreCataloguedWithTheirRetryClasses() {
    #expect(DaemonMethod.imageUpdateCheck.rawValue == "image.update.check")
    #expect(DaemonMethod.imageUpdateRun.rawValue == "image.update.run")
    #expect(DaemonMethod.imageUpdateStatus.rawValue == "image.update.status")
    #expect(DaemonMethod.imageUpdateCheck.methodClass == .idempotentMutation)
    #expect(DaemonMethod.imageUpdateRun.methodClass == .idempotentMutation)
    #expect(DaemonMethod.imageUpdateStatus.methodClass == .readOnly)
    for method in [DaemonMethod.imageUpdateCheck, .imageUpdateRun, .imageUpdateStatus] {
      #expect(method.isImplemented, "\(method)")
    }
  }

  /// `status` reads the table, not the service, so it answers on a daemon with no updater wired.
  @Test func statusReportsTracksEvenWithNoUpdateServiceWired() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      _ = await harness.imageUpdates(configuration: config)
      let service = harness.service()

      let response = try await service.imageUpdateStatus()

      #expect(response.tracks.map(\.name) == [reference])
      #expect(response.tracks.first?.kind == "registryTag")
      #expect(response.tracks.first?.state == "idle")
      #expect(response.tracks.first?.autoUpdate == true)
      #expect(response.tracks.first?.currentImageDigest == nil)

      // But driving one is refused rather than silently doing nothing.
      await #expect(throws: OrchestrationError.self) {
        try await service.imageUpdateCheck(ImageUpdateCheckRequest())
      }
    }
  }

  @Test func checkAndRunGoThroughTheServiceAndRefuseAnUnknownTrack() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let published = try await ImageUpdateTests.publish(harness)
      let updates = await harness.imageUpdates(configuration: config)
      let service = harness.service(updates: updates)

      let checked = try await service.imageUpdateCheck(
        ImageUpdateCheckRequest(managed: reference))
      #expect(checked.tracks.count == 1)
      #expect(checked.tracks.first?.lastCheckedAt != nil)
      #expect(published.chunkFetches(harness.registry) == 0)

      _ = try await service.imageUpdateRun(ImageUpdateRunRequest(managed: reference))
      // `run` answers before the cycle finishes, so the outcome is read back afterwards.
      try await waitUntil("the manual cycle to promote") {
        try await harness.managedRows.get(name: reference)?.currentImageDigest != nil
      }

      let unknown = await Self.code {
        try await service.imageUpdateRun(ImageUpdateRunRequest(managed: "nope"))
      }
      #expect(unknown == "MANAGED_IMAGE_NOT_FOUND")
    }
  }

  /// `run` claims its tracks before answering, so a `--wait` that polls immediately cannot mistake
  /// "the cycle has not started" for "the cycle has finished".
  @Test func runReportsTheTrackAsRunningBeforeItAnswers() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await ImageUpdateTests.publish(harness)
      let updates = await harness.imageUpdates(configuration: config)
      let service = harness.service(updates: updates)

      let started = try await service.imageUpdateRun(ImageUpdateRunRequest())

      #expect(started.tracks.map(\.state) == ["checking"])
      try await waitUntil("the manual cycle to settle") {
        try await harness.managedRows.get(name: reference)?.state == .idle
      }
      #expect(try await harness.managedTrack(reference).currentImageDigest != nil)
    }
  }

  /// A row a previous process left mid-pull has no edge back to `idle` and would be skipped by
  /// every later sweep, so startup lands it in `failed` -- nothing was promoted, and the next
  /// cycle retries from scratch.
  @Test func aTrackLeftMidCycleByARestartIsRecoveredIntoFailed() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await ImageUpdateTests.publish(harness)
      _ = await harness.imageUpdates(configuration: config)
      _ = try await harness.managedRows.transition(
        name: reference, from: .idle, to: .checking) { _ in }
      _ = try await harness.managedRows.transition(
        name: reference, from: .checking, to: .downloading) { _ in }

      let restarted = await harness.imageUpdates(configuration: config)
      await restarted.recoverInterrupted()

      let recovered = try await harness.managedTrack(reference)
      #expect(recovered.state == .failed)
      #expect(recovered.lastError?.contains("downloading") == true)

      await restarted.runCycle()

      #expect(try await harness.managedTrack(reference).state == .idle)
      #expect(try await harness.managedTrack(reference).currentImageDigest != nil)
    }
  }

  /// `runnerctl status` renders the block from `system.status`, following the `Builds:` precedent.
  @Test func systemStatusCarriesTheTracksAndDropsTheBlockWhenThereAreNone() async throws {
    let registry = FakeRegistry()
    let reference = try ImageUpdateTests.reference(registry)
    try await withHarness(registry: registry) { harness in
      #expect(try await harness.service().status().updates == nil)

      let config = M2Harness.updateConfiguration(image: reference)
      _ = await harness.imageUpdates(configuration: config)

      let tracks = try #require(try await harness.service().status().updates)
      #expect(tracks.map(\.name) == [reference])
    }
  }

  private static func code(_ body: () async throws -> Void) async -> String? {
    do {
      try await body()
      return nil
    } catch let error as any RunnerError {
      return error.code
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }
}
