import Foundation
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// One track's resolve → pull → qualify → promote pass. Split out of `ImageUpdateService.swift` to
/// keep that file under its line budget; every member below runs actor-isolated on
/// `ImageUpdateService` exactly as if it were declared there.
extension ImageUpdateService {
  /// A track already mid-cycle is left alone: `checking`/`downloading`/`qualifying`/`promoting`
  /// mean another pass (or a previous daemon) owns it, and `ManagedImageState` has no edge back
  /// into itself. A row a crash left mid-flight is recovered by hand rather than by racing it.
  ///
  /// `reserved` means the caller already claimed the row (`ImageUpdateService.startCycle`), so it
  /// is `checking` on entry and the guard below would refuse the very pass that owns it.
  func cycle(_ track: ManagedImageRecord, resolveOnly: Bool, reserved: Bool = false) async {
    guard reserved || track.state == .idle || track.state == .failed else {
      logger.info(
        "managed image is already mid-cycle",
        metadata: ["managed": .string(track.name), "state": .string(track.state.rawValue)])
      return
    }
    do {
      switch track.kind {
      case .registryTag: try await runRegistryTag(track, reserved: reserved, resolveOnly: resolveOnly)
      case .macosTart: try await runMacOSTart(track, reserved: reserved, resolveOnly: resolveOnly)
      }
    } catch {
      await recordFailure(track, error: error)
    }
  }

  // MARK: - Registry tag

  /// The Linux path: the upstream artifact is directly runnable, so the candidate is a pull.
  private func runRegistryTag(
    _ track: ManagedImageRecord, reserved: Bool, resolveOnly: Bool
  ) async throws {
    if !reserved {
      _ = try await managed.transition(name: track.name, from: track.state, to: .checking) { row in
        row.lastError = nil
      }
    }
    let source = try await images.resolveSourceDigest(reference: track.sourceReference)
    await noteCheck(kind: .registryTag)
    // `lastSourceDigest` is written at promotion and nowhere else, so it always names the upstream
    // manifest the *promoted* image came from. A check that recorded it here would make the next
    // scheduled sweep believe the move had already been acted on and skip the pull entirely.
    let unchanged = source.rawValue == track.lastSourceDigest && track.currentImageDigest != nil
    guard !unchanged, !resolveOnly else {
      _ = try await managed.transition(name: track.name, from: .checking, to: .idle) { row in
        row.lastCheckedAt = .now
      }
      return
    }
    let candidate = try await pullCandidate(track, source: source)
    try await qualify(track, candidate: candidate)
    try await promote(track, source: source, candidate: candidate.record.digest)
  }

  /// `.instance` purpose, deliberately: an upstream that has lost its guest agent is refused after
  /// its config blobs and before a byte of disk moves (spec §58), and the refusal becomes this
  /// track's `last_error` while the working image stays exactly where it is.
  private func pullCandidate(
    _ track: ManagedImageRecord, source: ImageDigest
  ) async throws -> ManagedImage {
    _ = try await managed.transition(name: track.name, from: .checking, to: .downloading) { row in
      row.lastCheckedAt = .now
    }
    let record = try await images.pull(reference: track.sourceReference, purpose: .instance)
    _ = try await managed.transition(name: track.name, from: .downloading, to: .qualifying) { row in
      row.candidateImageDigest = record.digest
    }
    return try await images.get(reference: record.digest.rawValue)
  }

  // MARK: - Qualification

  /// Everything that must hold before a candidate is allowed to become what a profile resolves to.
  /// Any failure here leaves the promoted image untouched -- that is the whole contract.
  private func qualify(_ track: ManagedImageRecord, candidate: ManagedImage) async throws {
    guard let metadata = candidate.metadata else {
      throw OrchestrationError.managedImageQualificationFailed(
        name: track.name, reason: "the candidate image has no readable metadata.json")
    }
    guard metadata.hasGuestAgent else {
      throw ImageError.noGuestAgent(
        digest: candidate.record.digest, reference: track.sourceReference)
    }
    let users = profiles(using: track.sourceReference)
    let guestKinds = Set(users.map(\.guestOS))
    guard guestKinds.count <= 1 else {
      throw OrchestrationError.managedImageMixedGuestOS(
        name: track.name, guestKinds: guestKinds.map(\.rawValue).sorted())
    }
    if let expected = guestKinds.first, expected != metadata.os {
      throw ImageError.incompatibleGuestOS(expected: expected, actual: metadata.os)
    }
    if await runnerVersions?.health(for: metadata) == .tooOld {
      let latest = await runnerVersions?.latest()?.version ?? "-"
      throw ImageError.runnerTooOld(
        digest: candidate.record.digest, imageVersion: metadata.runnerVersion,
        latestVersion: latest)
    }
    guard policy.smokeTest, let profile = users.first(where: { $0.guestOS == .linux }) else {
      return
    }
    try await smokeTest(track, candidate: candidate.record.digest, profile: profile.name)
  }

  /// Profiles pointing at this exact reference, in configuration order. The applied document only
  /// carries profiles this host is meant to run, so no `enabled` filter is needed here.
  private func profiles(using reference: String) -> [RunnerProfileConfig] {
    let all: [RunnerProfileConfig] = configuration?.profiles ?? []
    return all.filter { ImageUpdateService.trackedReference($0.image) == reference }
  }

  /// The boot-to-idle gate: a pinned maintenance VM built from the *candidate* digest, which has
  /// to reach `idle` -- clone, worker, boot, guest-agent handshake -- before anything is promoted.
  ///
  /// A maintenance instance is used rather than a runner one because the scheduler must never see
  /// it: it holds real host capacity while it runs, is never handed a job, and is reclaimed by its
  /// own ttl if this daemon dies mid-qualification.
  private func smokeTest(
    _ track: ManagedImageRecord, candidate: ImageDigest, profile: String
  ) async throws {
    let record = try await instances.create(
      profileName: profile,
      options: InstanceCreateOptions(
        purpose: .maintenance,
        pinnedUntil: tuning.now().addingTimeInterval(Self.seconds(tuning.smokeTestTTL)),
        imageOverride: candidate.rawValue))
    logger.info(
      "qualifying a candidate image",
      metadata: .context(instance: record.id, imageDigest: candidate)
        .merging(["managed": .string(track.name), "profile": .string(profile)]) { $1 })
    do {
      try await waitForIdle(record.id, track: track.name)
    } catch {
      _ = try? await instances.delete(id: record.id)
      throw error
    }
    _ = try? await instances.delete(id: record.id)
  }

  /// Polled rather than event-driven: `LifecycleEventLog` is an optional observability sink this
  /// service is not wired to, and a bounded poll against the row the transition already wrote is
  /// the same answer without the dependency.
  private func waitForIdle(_ id: InstanceID, track: String) async throws {
    let interval = Self.seconds(tuning.smokeTestPollInterval)
    let attempts = max(1, Int((Self.seconds(tuning.smokeTestTimeout) / max(interval, 0.001)).rounded()))
    for _ in 0..<attempts {
      guard let row = try await instanceRows.get(id: id) else {
        throw OrchestrationError.managedImageQualificationFailed(
          name: track, reason: "the qualification VM disappeared before reaching 'idle'")
      }
      if row.state == .idle { return }
      guard !Self.qualificationLost.contains(row.state) else {
        let detail = row.failureMessage ?? row.failureCode ?? "no detail recorded"
        throw OrchestrationError.managedImageQualificationFailed(
          name: track, reason: "the qualification VM reached '\(row.state.rawValue)': \(detail)")
      }
      try await Task.sleep(for: tuning.smokeTestPollInterval)
    }
    throw OrchestrationError.managedImageQualificationFailed(
      name: track,
      reason: "the qualification VM did not reach 'idle' within "
        + "\(Int(Self.seconds(tuning.smokeTestTimeout)))s")
  }

  /// States a qualification VM can only reach by failing: it is never given a job, so anything
  /// past `idle` on the runner ladder is out of scope here.
  private static let qualificationLost: Set<InstanceState> = [
    .failed, .interrupted, .orphaned, .stopping, .stopped, .deleting, .deleted,
  ]

  // MARK: - Promotion

  /// The atomic half. One row write moves `current_image_digest`, and from that instant
  /// `ImagePulling.resolveRecord` answers every `vm create` with the new digest -- no alias
  /// rewrite, no cache invalidation, no window in which half the host is on each image.
  private func promote(
    _ track: ManagedImageRecord, source: ImageDigest, candidate: ImageDigest
  ) async throws {
    _ = try await managed.transition(name: track.name, from: .qualifying, to: .promoting) { _ in }
    // Before anything is unpinned: the candidate must never be observably unpinnable, and this
    // pin is what makes `image.prune` leave the promoted image alone.
    try await imageRows.pin(ownerType: .managed, ownerId: track.name, digest: candidate)
    try await imageRows.unpin(
      ownerType: .managedPrevious, ownerId: track.name, digest: candidate)
    var previous = (try? track.decodedPreviousDigests()) ?? []
    if let superseded = track.currentImageDigest, superseded != candidate {
      try await imageRows.unpin(ownerType: .managed, ownerId: track.name, digest: superseded)
      try await imageRows.pin(
        ownerType: .managedPrevious, ownerId: track.name, digest: superseded)
      previous.append(superseded)
    }
    // A digest that has come back round is current again, not retained.
    previous.removeAll { $0 == candidate }
    let keep = policy.keepPrevious
    let evicted = previous.count > keep ? Array(previous.prefix(previous.count - keep)) : []
    previous = Array(previous.suffix(keep))
    let encoded = try ManagedImageRecord.encodePreviousDigests(previous)
    _ = try await managed.transition(name: track.name, from: .promoting, to: .idle) { row in
      row.currentImageDigest = candidate
      row.candidateImageDigest = nil
      row.lastSourceDigest = source.rawValue
      row.previousDigestsJson = encoded
      row.lastUpdatedAt = .now
      row.lastError = nil
    }
    logger.notice(
      "managed image promoted",
      metadata: .context(imageDigest: candidate).merging([
        "managed": .string(track.name), "source_digest": .string(source.rawValue),
        "superseded": .string(track.currentImageDigest?.rawValue ?? "-"),
      ]) { $1 })
    await metrics.increment(
      RunnerVMMetrics.imageUpdatePromotionsTotal,
      labels: [RunnerVMMetrics.kindLabel: track.kind.rawValue])
    await release(evicted, track: track.name)
    // Spec §138: reusable VMs still on the superseded digest retire once their session ends.
    // `retireOutdatedReusable` applies `imageUpdates.recycleReusable` itself and answers 0 when
    // it is off, so the policy lives in exactly one place.
    _ = await instances.retireOutdatedReusable()
  }

  /// `images.updates.keepPrevious` is the only deletion trigger, and `ImageManager.delete` still
  /// has the last word: a digest a live instance or another pin still holds is logged and left,
  /// unpinned, for a later `image.prune` to reclaim.
  private func release(_ digests: [ImageDigest], track: String) async {
    for digest in digests {
      try? await imageRows.unpin(ownerType: .managedPrevious, ownerId: track, digest: digest)
      do {
        try await images.delete(digest: digest)
      } catch {
        logger.info(
          "superseded managed image kept: still referenced",
          metadata: .context(imageDigest: digest).merging([
            "managed": .string(track), "reason": .string(ImageUpdateService.message(error)),
          ]) { $1 })
      }
    }
  }

  // MARK: - macOS Tart source

  /// Phase D6 tracks a Tart source without acting on it: the export carries no guest agent, so
  /// there is nothing to pull-and-promote -- the candidate has to be *provisioned* into a new,
  /// locally sealed image first, which is D7's `MacOSProvisionLauncher`.
  private func runMacOSTart(
    _ track: ManagedImageRecord, reserved: Bool, resolveOnly: Bool
  ) async throws {
    if !reserved {
      _ = try await managed.transition(name: track.name, from: track.state, to: .checking) { row in
        row.lastError = nil
      }
    }
    let source = try await images.resolveSourceDigest(reference: track.sourceReference)
    await noteCheck(kind: .macosTart)
    let changed = source.rawValue != track.lastSourceDigest || track.currentImageDigest == nil
    let pending = changed && track.autoUpdate && provisioning == nil
    _ = try await managed.transition(name: track.name, from: .checking, to: .idle) { row in
      row.lastSourceDigest = source.rawValue
      row.lastCheckedAt = .now
      // The breadcrumb *is* the state: it survives a restart, `image.update.status` reports it,
      // and a promotion is the only thing that clears it.
      row.lastError = pending ? ImageUpdateService.provisioningPending : nil
    }
    guard changed, track.autoUpdate, !resolveOnly else { return }
    logger.notice(
      "managed macOS source moved",
      metadata: [
        "managed": .string(track.name), "source": .string(track.sourceReference),
        "source_digest": .string(source.rawValue),
        "provisioning": .string(provisioning == nil ? "unavailable (phase D7)" : "queued"),
      ])
    guard let provisioning else { return }
    await provisioning.provision((try? await managed.get(name: track.name)) ?? track)
  }

  // MARK: - Failure

  /// A failure never touches `current_image_digest`: the alias stays on the last known-good digest
  /// and the reason is recorded for `image.update.status` and the next cycle.
  private func recordFailure(_ track: ManagedImageRecord, error: any Error) async {
    let reason = ImageUpdateService.message(error)
    if var current = try? await managed.get(name: track.name) {
      current.lastError = reason
      current.candidateImageDigest = nil
      current.updatedAt = .now
      // `failed -> failed` is not an edge in `ManagedImageState`, so a row that is already there
      // is refreshed in place rather than transitioned.
      if current.state == .failed {
        try? await managed.upsert(current)
      } else {
        _ = try? await managed.transition(name: track.name, from: current.state, to: .failed) {
          row in
          row.lastError = reason
          row.candidateImageDigest = nil
        }
      }
    }
    await metrics.increment(
      RunnerVMMetrics.imageUpdateFailuresTotal,
      labels: [RunnerVMMetrics.kindLabel: track.kind.rawValue])
    logger.warning(
      "managed image update failed",
      metadata: [
        "managed": .string(track.name), "source": .string(track.sourceReference),
        "current": .string(track.currentImageDigest?.rawValue ?? "-"),
        "error": .string(reason),
      ])
  }
}
