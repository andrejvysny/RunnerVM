import Foundation
import OCIRegistry
import Persistence
import RunnerCore

/// The two `managed_images` seams on `ImageManager` (phase D6): the promotion lookup that makes a
/// tracked tag resolve to a qualified digest, and the cache-bypassing resolve the update service
/// needs to notice that a tag has moved. Same actor, same isolation as `ImagePulling.swift`.
extension ImageManager {
  /// The digest a managed-image track has promoted for exactly this reference, when it is still
  /// `ready` on disk -- consulted before the tag cache and before any network touch.
  ///
  /// This is what makes a promotion atomic for the job path: `ImageUpdateService` pulls and
  /// qualifies a candidate without anything resolving to it, then writes `current_image_digest` in
  /// one row update, and from that instant every `vm create` gets the new digest. Without it, the
  /// candidate's own pull would have seeded `tagResolutions` and un-qualified bytes would be
  /// booting jobs.
  ///
  /// Only tag references: a profile pinned to `@sha256:…` is never auto-updated, and a track is
  /// never keyed by one.
  func promotedRecord(_ ref: OCIReference) async throws -> ImageRecord? {
    guard let managed, ref.digest == nil else { return nil }
    guard let track = try await managed.get(name: ref.description), track.kind == .registryTag,
          let digest = track.currentImageDigest,
          let record = try await images.get(digest: digest), record.state == .ready
    else { return nil }
    return record
  }

  /// The manifest digest `reference` resolves to *right now*, bypassing `tagResolutions`.
  ///
  /// `inspectRemote` deliberately caches and reuses a five-minute-old answer, which is right for
  /// the pull path and exactly wrong for the update service: noticing that a tag has moved is the
  /// whole job. Nothing is written here -- not the cache, not a row -- so a resolve that finds
  /// nothing new costs one manifest plus two config blobs and leaves no trace.
  ///
  /// Purpose is `.storage`: an agentless upstream must resolve so the failure can be reported
  /// against the candidate rather than swallowed as an unreachable registry. The pull that follows
  /// uses `.instance` and is what refuses it.
  public func resolveSourceDigest(reference: String) async throws -> ImageDigest {
    let ref = try Self.requireRegistryReference(reference)
    let remote = try await RunnerVMImageTransfer.inspect(
      ref, registry: try await registries.client(for: ref.registry))
    return remote.digest
  }
}
