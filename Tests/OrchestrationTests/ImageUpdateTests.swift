import Foundation
import ImageStore
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Phase D6: `ImageUpdateService`. Everything runs against `FakeRegistry` inside `withHarness`, so
/// a "the tag moved" test is a real registry round trip and a promotion is a real pull.
@Suite struct ImageUpdateTests {
  static let repository = "acme/runners/ubuntu-24"
  static let tag = "stable"

  static func reference(_ registry: FakeRegistry) throws -> String {
    try registry.reference(repository, tag: tag).description
  }

  /// Publishes (or re-publishes) the tracked tag. A different `seed` is different bytes, so both
  /// the manifest digest the update service resolves and the local content digest it promotes
  /// change -- which is exactly what "upstream moved" means.
  @discardableResult
  static func publish(
    _ harness: M2Harness, seed: UInt8 = 1, guestAgent: Bool = true, at directory: String = "origin"
  ) async throws -> PublishedImage {
    try await PublishedImage.publish(
      into: harness.registry, at: harness.tree.root.appending(path: directory),
      repository: repository, tag: tag, seed: seed, guestAgent: guestAgent)
  }

  // MARK: - Checking

  /// The cheap steady state: one manifest resolution, no transfer, and the row only records that
  /// it looked.
  @Test func anUnchangedTagIsCheckedWithoutPullingAnything() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let published = try await Self.publish(harness)
      let updates = await harness.imageUpdates(configuration: config)
      await updates.runCycle()
      let promoted = try await harness.managedTrack(reference)
      #expect(promoted.state == .idle)
      let digest = try #require(promoted.currentImageDigest)

      // Backdated so "the timestamp advanced" is an assertion, not a millisecond race.
      var aged = promoted
      aged.lastCheckedAt = DatabaseDate(Date(timeIntervalSince1970: 1_000))
      try await harness.managedRows.upsert(aged)
      harness.registry.resetRecording()

      await updates.runCycle()

      let after = try await harness.managedTrack(reference)
      #expect(after.state == .idle)
      #expect(after.currentImageDigest == digest)
      #expect(try #require(after.lastCheckedAt).date > Date(timeIntervalSince1970: 1_000))
      #expect(published.chunkFetches(harness.registry) == 0)
    }
  }

  /// `check` is resolve-only *and* must not poison the next sweep: recording the freshly resolved
  /// digest as `last_source_digest` would make the scheduled cycle believe the move had already
  /// been acted on.
  @Test func aResolveOnlyCheckNeverPullsAndNeverSuppressesTheNextUpdate() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let published = try await Self.publish(harness)
      let updates = await harness.imageUpdates(configuration: config)

      await updates.check()

      let checked = try await harness.managedTrack(reference)
      #expect(checked.state == .idle)
      #expect(checked.lastCheckedAt != nil)
      #expect(checked.currentImageDigest == nil)
      #expect(checked.lastSourceDigest == nil)
      #expect(published.chunkFetches(harness.registry) == 0)
      #expect(try await harness.imageRows.list(state: nil).isEmpty)

      await updates.runCycle()

      let promoted = try await harness.managedTrack(reference)
      #expect(promoted.currentImageDigest != nil)
      #expect(promoted.lastSourceDigest == published.manifestDigest.rawValue)
    }
  }

  // MARK: - Promotion

  @Test func aMovedTagIsPulledQualifiedAndPromoted() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let first = try await Self.publish(harness, seed: 1)
      let updates = await harness.imageUpdates(configuration: config)
      await updates.runCycle()
      let firstDigest = try #require(try await harness.managedTrack(reference).currentImageDigest)

      let second = try await Self.publish(harness, seed: 7, at: "origin-2")
      #expect(second.manifestDigest != first.manifestDigest)
      await updates.runCycle()

      let track = try await harness.managedTrack(reference)
      let secondDigest = try #require(track.currentImageDigest)
      #expect(secondDigest != firstDigest)
      #expect(track.state == .idle)
      #expect(track.candidateImageDigest == nil)
      #expect(track.lastError == nil)
      #expect(track.lastSourceDigest == second.manifestDigest.rawValue)
      #expect(track.lastUpdatedAt != nil)
      #expect(try track.decodedPreviousDigests() == [firstDigest])

      // The promotion is what the job path sees, and it costs no registry traffic at all.
      harness.registry.resetRecording()
      #expect(try await harness.images.resolve(reference: reference) == secondDigest)
      #expect(harness.registryRequestCount == 0)

      #expect(try await harness.imageRows.pins(ownerType: .managed).map(\.digest) == [secondDigest])
      #expect(
        try await harness.imageRows.pins(ownerType: .managedPrevious).map(\.digest)
          == [firstDigest])
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.imageUpdatePromotionsTotal, labels: ["kind": "registryTag"]) == 2)
      #expect(await harness.metrics.gauge(name: RunnerVMMetrics.imageUpdateLastCheckTimestamp) != nil)
    }
  }

  /// Spec §138: a running VM keeps the digest it booted with, but a *reusable* one on a superseded
  /// digest is armed to retire the moment its session ends.
  @Test func promotionRetiresReusableVMsLeftOnTheSupersededDigest() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference, lifecycle: .reusable)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await Self.publish(harness, seed: 1)
      let updates = await harness.imageUpdates(configuration: config)
      await updates.runCycle()
      let firstDigest = try #require(try await harness.managedTrack(reference).currentImageDigest)

      let record = try await harness.instances.create(profileName: "linux")
      #expect(record.imageDigest == firstDigest)
      let agent = try await harness.startGuestAgent(for: record.id)
      try await harness.awaitInstance(record.id, state: .idle)

      try await Self.publish(harness, seed: 7, at: "origin-2")
      await updates.runCycle()

      #expect(try await harness.record(record.id).retireAfterSession)
      // Never terminated, only armed: the job on it (if any) finishes on the image it booted.
      #expect(try await harness.record(record.id).state == .idle)
      #expect(try await harness.record(record.id).imageDigest == firstDigest)
      await agent.stop()
    }
  }

  // MARK: - Retention

  /// `keepPrevious` is the only deletion trigger: the digest that falls out of the window is
  /// unpinned and deleted, the one inside it stays pinned and on disk.
  @Test func retentionKeepsOnePreviousDigestAndDeletesTheOneBeforeIt() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference, keepPrevious: 1)
    try await withHarness(configuration: config, registry: registry) { harness in
      let updates = await harness.imageUpdates(configuration: config)
      var digests: [ImageDigest] = []
      for (index, seed) in [UInt8(1), 7, 9].enumerated() {
        try await Self.publish(harness, seed: seed, at: "origin-\(index)")
        await updates.runCycle()
        digests.append(try #require(try await harness.managedTrack(reference).currentImageDigest))
      }
      #expect(Set(digests).count == 3)

      let track = try await harness.managedTrack(reference)
      #expect(track.currentImageDigest == digests[2])
      #expect(try track.decodedPreviousDigests() == [digests[1]])
      #expect(try await harness.imageRows.pins(ownerType: .managed).map(\.digest) == [digests[2]])
      #expect(
        try await harness.imageRows.pins(ownerType: .managedPrevious).map(\.digest)
          == [digests[1]])
      // The oldest is gone from the row *and* the store; the retained one is still both.
      #expect(try await harness.imageRows.get(digest: digests[0]) == nil)
      #expect(try await harness.imageStore.exists(digests[0]) == false)
      #expect(try await harness.imageRows.get(digest: digests[1]) != nil)
      #expect(try await harness.imageStore.exists(digests[1]))
    }
  }

  // MARK: - Failure

  /// The central invariant: a candidate that cannot run a job never replaces the one that can.
  @Test func anAgentlessCandidateFailsAndLeavesThePromotedImageAlone() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      let good = try await Self.publish(harness, seed: 1)
      let updates = await harness.imageUpdates(configuration: config)
      await updates.runCycle()
      let promoted = try #require(try await harness.managedTrack(reference).currentImageDigest)

      try await Self.publish(harness, seed: 7, guestAgent: false, at: "origin-agentless")
      await updates.runCycle()

      let track = try await harness.managedTrack(reference)
      #expect(track.state == .failed)
      #expect(track.currentImageDigest == promoted)
      #expect(track.candidateImageDigest == nil)
      #expect(track.lastSourceDigest == good.manifestDigest.rawValue)
      #expect(track.lastError?.isEmpty == false)
      // The job path still resolves to the last known-good digest.
      #expect(try await harness.images.resolve(reference: reference) == promoted)
      #expect(
        await harness.metrics.counter(
          name: RunnerVMMetrics.imageUpdateFailuresTotal, labels: ["kind": "registryTag"]) == 1)
    }
  }

  /// A `failed` track re-attempts on the next pass rather than parking forever, and a fixed
  /// upstream recovers it without operator action.
  @Test func aFailedTrackRetriesAndRecoversOnceUpstreamIsFixed() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await Self.publish(harness, seed: 7, guestAgent: false)
      let updates = await harness.imageUpdates(configuration: config)
      await updates.runCycle()
      #expect(try await harness.managedTrack(reference).state == .failed)
      #expect(try await harness.managedTrack(reference).currentImageDigest == nil)

      try await Self.publish(harness, seed: 3, guestAgent: true, at: "origin-fixed")
      await updates.runCycle()

      let track = try await harness.managedTrack(reference)
      #expect(track.state == .idle)
      #expect(track.lastError == nil)
      #expect(track.currentImageDigest != nil)
    }
  }

  // MARK: - Smoke test gate

  /// `images.updates.smokeTest` boots the *candidate* as a pinned maintenance VM and only promotes
  /// once it reaches `idle` -- clone, worker, boot and guest-agent handshake included.
  @Test func theSmokeTestGateBootsTheCandidateBeforePromoting() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference, smokeTest: true)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await Self.publish(harness, seed: 1)
      let updates = await harness.imageUpdates(configuration: config)

      async let ran: [ManagedImageRecord] = updates.runCycle()
      let rows = harness.instanceRows
      try await waitUntil("the qualification VM row to exist") {
        try await rows.list(profile: nil, states: nil).contains { $0.purpose == .maintenance }
      }
      let pinned = try #require(
        try await rows.list(profile: nil, states: nil).first { $0.purpose == .maintenance })
      let agent = try await harness.startGuestAgent(for: pinned.id)
      _ = await ran
      await agent.stop()

      let track = try await harness.managedTrack(reference)
      let promoted = try #require(track.currentImageDigest)
      #expect(track.state == .idle)
      #expect(pinned.imageDigest == promoted)
      // The gate cleans up after itself: nothing is left holding host capacity.
      #expect(try await harness.record(pinned.id).state == .deleted)
    }
  }

  // MARK: - Restart

  /// Two services over one database: the rows are the durable state, so a restart resumes the
  /// track instead of re-promoting from scratch.
  @Test func trackRowsSurviveARestartAndTheCycleResumes() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await Self.publish(harness, seed: 1)
      let first = await harness.imageUpdates(configuration: config)
      await first.runCycle()
      let promoted = try #require(try await harness.managedTrack(reference).currentImageDigest)

      try await Self.publish(harness, seed: 7, at: "origin-2")
      let second = await harness.imageUpdates(configuration: config)
      // Constructing a second service re-derives the tracks and must not reset any of them.
      let carried = try await harness.managedTrack(reference)
      #expect(carried.currentImageDigest == promoted)
      #expect(carried.state == .idle)

      await second.runCycle()

      let track = try await harness.managedTrack(reference)
      #expect(track.currentImageDigest != promoted)
      #expect(try track.decodedPreviousDigests() == [promoted])
    }
  }

  // MARK: - Policy

  /// A host that does not update itself still answers `image.update.run`: the operator asking for
  /// one update is not the same thing as the host doing it unattended.
  @Test func aDisabledPolicyStopsTheSweepButNotAManualRun() async throws {
    let registry = FakeRegistry()
    let reference = try Self.reference(registry)
    let config = M2Harness.updateConfiguration(image: reference, enabled: false)
    try await withHarness(configuration: config, registry: registry) { harness in
      try await Self.publish(harness, seed: 1)
      let updates = await harness.imageUpdates(configuration: config)
      harness.registry.resetRecording()

      await updates.runScheduledCycle()

      // Tracked, but untouched: the row exists because bookkeeping is unconditional.
      let idle = try await harness.managedTrack(reference)
      #expect(idle.lastCheckedAt == nil)
      #expect(idle.currentImageDigest == nil)
      #expect(harness.registryRequestCount == 0)

      await updates.runCycle()

      #expect(try await harness.managedTrack(reference).currentImageDigest != nil)
    }
  }
}
