import Foundation

/// `instances.purpose` (`docs/db_schema_v4.sql`). A `maintenance` instance qualifies a candidate
/// managed image rather than running a job, so the scheduler and demand accounting exclude it.
public enum InstancePurpose: String, Codable, Sendable, CaseIterable, Hashable {
  case runner
  case maintenance
}

/// `image_builds.kind` (`docs/db_schema_v4.sql`). Distinguishes a macOS guest-provisioning build
/// from an ordinary Runnerfile build.
public enum ImageBuildKind: String, Codable, Sendable, CaseIterable, Hashable {
  case runnerfile
  case macosProvision
}

/// `managed_images.kind` (`docs/db_schema_v4.sql`): the kind of upstream source a managed image
/// tracks -- a container registry tag, or a Tart macOS image.
public enum ManagedImageKind: String, Codable, Sendable, CaseIterable, Hashable {
  case registryTag
  case macosTart
}
