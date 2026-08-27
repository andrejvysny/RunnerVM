import Foundation
import ImageStore
import Persistence
import RunnerCore

/// The image-catalogue operations the in-daemon builder needs, as `ImageManager` methods.
///
/// They live here rather than in `ImageBuilder` because every one of them has to run on the
/// `ImageManager` actor: that actor is the serialization point `prune` and `delete` also run on,
/// which is the only thing that makes "pin the base, then use it" and "publish the disk, then
/// register the row" safe against a concurrent `image.prune` (spec §110).
extension ImageManager {
  // MARK: - Base reservation

  /// Resolves (pulling if needed) and pins a build's `FROM` base under the `build` owner.
  ///
  /// Unlike `reserve(reference:for:)` this does **not** refuse an agentless image: a build knows
  /// its own rule (`BUILD_BASE_NO_GUEST_AGENT` names the recipe's reference, not a profile's) and
  /// applies it on the `ImageInfo` returned here.
  public func reserve(
    reference: String, forBuild buildId: ImageBuildID
  ) async throws -> (ImageDigest, ImageInfo) {
    let digest = try await resolveRecord(
      reference: reference, profile: nil, purpose: .buildBase).digest
    let info = try await store.inspect(digest: digest)
    try await images.pin(ownerType: .build, ownerId: buildId.rawValue, digest: digest)
    return (digest, info)
  }

  /// Idempotent: releasing a build that never pinned anything is success.
  public func release(build buildId: ImageBuildID) async throws {
    try await images.unpinOwner(ownerType: .build, ownerId: buildId.rawValue)
  }

  /// Startup safety net, the `build`-owner twin of `sweepStalePlanningPins`: a crash between
  /// pinning a base and writing the build row would otherwise hold that image hostage forever.
  @discardableResult
  public func sweepStaleBuildPins(knownBuildIDs: Set<ImageBuildID>) async throws -> Int {
    let orphaned = try await images.pins(ownerType: .build)
      .filter { !knownBuildIDs.contains(ImageBuildID(rawValue: $0.ownerId)) }
    for pin in orphaned {
      try await images.unpin(ownerType: .build, ownerId: pin.ownerId, digest: pin.digest)
    }
    return orphaned.count
  }

  // MARK: - Seal

  /// Publishes a finished builder VM's disk as an image and registers it.
  ///
  /// `ImageSealer` refuses while the build's `worker.lock` is still held, so a disk can never be
  /// hashed underneath a live vmworker. The alias is set last and is what makes `--name` mean the
  /// new digest from this moment on (B5: last successful registration wins).
  public func sealBuild(
    directory: URL, metadata: ImageMetadata, name: String?
  ) async throws -> ManagedImage {
    let sealed = try await ImageSealer(images: store, logger: logger).seal(
      instanceDirectory: directory, as: metadata, name: name)
    return try await register(sealed.digest, directory: sealed.manifestDirectory, name: name)
  }

  /// Restart recovery (B4): the store already holds the sealed content -- `sealAndRegister` wrote
  /// `image_digest` to the build row before deleting the VM directory -- so the row and the alias
  /// are all that is missing. Re-running the seal is impossible: the disk it hashed is gone.
  public func sealBuildReplay(digest: ImageDigest, name: String?) async throws -> ManagedImage {
    guard let directory = store.manifestDirectory(for: digest), await store.exists(digest) else {
      throw ImageError.notFound(reference: digest.rawValue)
    }
    return try await register(digest, directory: directory, name: name)
  }

  private func register(
    _ digest: ImageDigest, directory: URL, name: String?
  ) async throws -> ManagedImage {
    let info = try await store.inspect(digest: digest)
    let record = try makeRecord(info: info, directory: directory, name: name)
    try await images.upsert(record)
    if let name { try await images.setAlias(name: name, digest: digest) }
    return ManagedImage(
      record: record, allocatedBytes: info.allocatedBytes,
      pinCount: try await images.pinCount(digest: digest),
      name: info.manifest.name ?? name, metadata: info.metadata)
  }
}
