import Foundation
import Persistence
import RunnerCore

/// Read-side lookups, split out of `ImageManager.swift` to keep that file under the 500-line
/// budget. Same actor, same rules: a reference is a digest, an alias, a canonical registry
/// reference or the immutable manifest name, in that order.
extension ImageManager {
  // MARK: - Read

  public func list() async throws -> [ManagedImage] {
    var result: [ManagedImage] = []
    for record in try await images.list(state: nil).sorted(by: { $0.digest.rawValue < $1.digest.rawValue }) {
      result.append(try await decorate(record))
    }
    return result
  }

  /// `ref` is a `sha256:` digest or a local name (the label the image was imported under).
  public func get(reference: String) async throws -> ManagedImage {
    try await decorate(try await record(for: reference))
  }

  /// Profile `image:` values: a local name or digest resolves from the catalogue, a
  /// registry-qualified reference is resolved against the registry and pulled if missing
  /// (spec §21, §137). A tag is re-resolved at most once every `tagResolutionTTL`.
  public func resolve(reference: String) async throws -> ImageDigest {
    try await resolveRecord(reference: reference, profile: nil).digest
  }


  func record(for reference: String) async throws -> ImageRecord {
    if reference.hasPrefix("sha256:"),
       let found = try await images.get(digest: ImageDigest(rawValue: reference)) {
      return found
    }
    // A mutable local-name alias, when one has been registered, wins over both fallbacks below: it
    // is the only source of truth for "which digest does this name mean *right now*" once more
    // than one manifest has ever carried it (a rebuild, or a re-import under the same name).
    if let aliased = try await images.alias(name: reference),
       let found = try await images.get(digest: aliased) {
      return found
    }
    let all = try await images.list(state: nil)
    if let named = all.first(where: { $0.canonicalReference == reference }) {
      return named
    }
    // Pulling content this host had already imported overwrites `canonical_reference` with the
    // registry reference (spec §21); the label it was imported under survives in the immutable
    // local manifest, and must keep resolving.
    for row in all {
      if let info = try? await store.inspect(digest: row.digest), info.manifest.name == reference {
        return row
      }
    }
    throw ImageError.notFound(
      reference: "\(reference) (no local image with that name or digest; import one with "
        + "`runnerctl image import <disk> --name \(reference)`, or name a registry reference)")
  }
}
