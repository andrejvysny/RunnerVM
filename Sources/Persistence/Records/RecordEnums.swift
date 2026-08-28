import GRDB

// Small enums for CHECK-constrained text columns that have no corresponding RunnerCore type.
// Unlike `InstanceState`/`RunnerSessionState`/`HostMode`, these are not persisted state machines
// with an orchestrator-visible transition policy (spec `docs/state_machines.md` covers only the
// three above), so they live here rather than in `RunnerCore/StateMachines`.

/// `images.state` (`docs/db_schema_v1.sql`).
public enum ImageState: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case pulling
  case ready
  case invalid
  case deleting
}

/// `operations.state`.
public enum OperationState: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case pending
  case running
  case succeeded
  case failed
  case cancelled
}

/// `runner_sessions.jit_source`.
public enum JitSource: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case rest
  case scaleSet
}

/// `scale_set_inbox.status`.
public enum InboxStatus: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case intent
  case processed
  case deleted
}

/// `image_pins.owner_type`. Not CHECK-constrained in the schema; these are the owners the
/// orchestrator is expected to pin on behalf of (a warm-pool profile keeping its image resident,
/// a running instance keeping the image it booted from resident, or an instance still being
/// created keeping the image alive between `ImageManager.reserve` and the row landing) — see
/// `ImageRepository`.
public enum ImagePinOwnerType: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case profile
  case instance
  /// Held by `ImageManager.reserve(reference:for:)` from the moment an image is resolved for a
  /// not-yet-inserted instance until `InstanceManager.create` either converts it into an
  /// `.instance` pin or releases it on failure. `ownerId` is the future instance id.
  case planning
  /// Held by an in-progress image build against its `FROM image:` base, for the same reason
  /// `.planning` holds one for an instance: the base cannot be reclaimed out from under a build
  /// that has not finished cloning it yet. `ownerId` is the `ImageBuildID`.
  case build
  /// Exactly one per managed-image track, on its currently promoted digest (`ImageUpdateService`,
  /// phase D6). `ownerId` is `managed_images.name`. This is what makes a promoted image immune to
  /// `image.prune` while it is the answer a profile's registry tag resolves to.
  case managed
  /// Held on each superseded digest a track still retains (`images.updates.keepPrevious`).
  /// `ownerId` is `managed_images.name`, so one track can hold several of these at once; dropping
  /// the pin is what makes a digest past the retention count deletable.
  case managedPrevious = "managed-previous"
}

/// `image_builds.from_kind` (`docs/db_schema_v2.sql`).
public enum ImageBuildFromKind: String, Codable, Sendable, Hashable, CaseIterable, DatabaseValueConvertible {
  case image
  case cloudImage
  case registry
}
