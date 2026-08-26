import Foundation
import RunnerCore

// MARK: - image.*

public struct ImageInfoDTO: Codable, Sendable, Hashable {
  public var digest: String
  /// Local label the image was imported under; `nil` for an unnamed import.
  public var name: String?
  /// The immutable reference this host resolved the image from, `<registry>/<repo>@sha256:…`
  /// (spec §21). Equal to `name` for a locally imported image, `nil` when neither is set.
  public var canonicalReference: String?
  public var os: String
  public var architecture: String
  public var state: String
  public var virtualSizeBytes: UInt64
  public var allocatedSizeBytes: UInt64
  public var localPath: String
  public var pinCount: Int
  public var createdAt: String
  /// When the image finished pulling or importing; `nil` while it is still `pulling`.
  public var pulledAt: String?
  /// `actions/runner` version baked into the image; `nil` when the image carries no metadata for
  /// it (a raw `image import` synthesises metadata and cannot know).
  public var runnerVersion: String?
  /// That version graded against the newest published release (spec §53). `unknown` whenever the
  /// image or the daemon cannot answer, never an error.
  public var runnerVersionHealth: RunnerVersionHealth
  /// Build provenance, when the image was sealed with any; `nil` for images built before
  /// provenance existed or imported without their `metadata.json`.
  public var provenance: ImageProvenanceSummaryDTO?

  public init(
    digest: String, name: String?, os: String, architecture: String, state: String,
    virtualSizeBytes: UInt64, allocatedSizeBytes: UInt64, localPath: String, pinCount: Int,
    createdAt: String, canonicalReference: String? = nil, pulledAt: String? = nil,
    runnerVersion: String? = nil, runnerVersionHealth: RunnerVersionHealth = .unknown,
    provenance: ImageProvenanceSummaryDTO? = nil
  ) {
    self.digest = digest
    self.name = name
    self.canonicalReference = canonicalReference
    self.os = os
    self.architecture = architecture
    self.state = state
    self.virtualSizeBytes = virtualSizeBytes
    self.allocatedSizeBytes = allocatedSizeBytes
    self.localPath = localPath
    self.pinCount = pinCount
    self.createdAt = createdAt
    self.pulledAt = pulledAt
    self.runnerVersion = runnerVersion
    self.runnerVersionHealth = runnerVersionHealth
    self.provenance = provenance
  }
}

/// The readable part of `ImageMetadata.Provenance`. Deliberately a summary: the full package
/// manifest runs to hundreds of entries and belongs in `metadata.json`, not in every `image list`.
public struct ImageProvenanceSummaryDTO: Codable, Sendable, Hashable {
  public var baseImageSource: String?
  public var baseImageSHA256: String?
  public var runnerSHA256: String?
  public var guestAgentCommit: String?
  public var dockerVersion: String?
  public var kernelVersion: String?
  public var packageUpgrade: Bool?
  public var packageCount: Int?
  public var diskSHA256: String?
  public var builtAt: String?
  public var builderCommit: String?

  public init(
    baseImageSource: String? = nil, baseImageSHA256: String? = nil, runnerSHA256: String? = nil,
    guestAgentCommit: String? = nil, dockerVersion: String? = nil, kernelVersion: String? = nil,
    packageUpgrade: Bool? = nil, packageCount: Int? = nil, diskSHA256: String? = nil,
    builtAt: String? = nil, builderCommit: String? = nil
  ) {
    self.baseImageSource = baseImageSource
    self.baseImageSHA256 = baseImageSHA256
    self.runnerSHA256 = runnerSHA256
    self.guestAgentCommit = guestAgentCommit
    self.dockerVersion = dockerVersion
    self.kernelVersion = kernelVersion
    self.packageUpgrade = packageUpgrade
    self.packageCount = packageCount
    self.diskSHA256 = diskSHA256
    self.builtAt = builtAt
    self.builderCommit = builderCommit
  }
}

public struct ImageListResponse: Codable, Sendable, Hashable {
  public var images: [ImageInfoDTO]

  public init(images: [ImageInfoDTO]) { self.images = images }
}

public struct ImageImportRequest: Codable, Sendable, Hashable {
  /// Absolute path to a raw disk on this host; runnerd reads it, so it must be readable by the
  /// daemon rather than by the caller.
  public var path: String
  /// EFI variable store (Linux) or macOS auxiliary storage.
  public var nvramPath: String?
  /// `GuestOS` raw value.
  public var os: String
  public var name: String?
  /// Explicit sealed `metadata.json` to adopt. When `nil` the daemon looks for one next to
  /// `path`; naming a file that does not exist, or one that describes a different guest OS, is an
  /// error rather than a silent fallback.
  public var metadataPath: String?

  public init(
    path: String, nvramPath: String? = nil, os: String, name: String? = nil,
    metadataPath: String? = nil
  ) {
    self.path = path
    self.nvramPath = nvramPath
    self.os = os
    self.name = name
    self.metadataPath = metadataPath
  }
}

/// `sha256:<hex>` digest or a local name.
public struct ImageGetRequest: Codable, Sendable, Hashable {
  public var ref: String

  public init(ref: String) { self.ref = ref }
}

/// Spec §21, §137. The reply comes back as soon as the tag is resolved and the transfer is
/// started, so a multi-gigabyte pull never has to fit inside the socket's idle timeout; follow
/// `operationId` with `operation.get`.
public struct ImagePullRequest: Codable, Sendable, Hashable {
  /// A registry-qualified reference: `<registry>/<repository>[:tag][@sha256:…]`.
  public var reference: String

  public init(reference: String) { self.reference = reference }
}

public struct ImagePullResponse: Codable, Sendable, Hashable {
  /// `<registry>/<repository>@sha256:…` the reference resolved to.
  public var reference: String
  /// The registry manifest digest concurrent pulls deduplicate on.
  public var manifestDigest: String
  /// `nil` when the image was already in the store, so nothing was started.
  public var operationId: String?
  public var alreadyPresent: Bool
  /// Local content digest; set only when `alreadyPresent`.
  public var digest: String?

  public init(
    reference: String, manifestDigest: String, operationId: String?, alreadyPresent: Bool,
    digest: String?
  ) {
    self.reference = reference
    self.manifestDigest = manifestDigest
    self.operationId = operationId
    self.alreadyPresent = alreadyPresent
    self.digest = digest
  }
}

public struct ImagePushRequest: Codable, Sendable, Hashable {
  /// Local `sha256:` digest or the name the image was imported under.
  public var image: String
  /// Registry-qualified target; a tag is published alongside the digest.
  public var reference: String

  public init(image: String, reference: String) {
    self.image = image
    self.reference = reference
  }
}

public struct ImagePushResponse: Codable, Sendable, Hashable {
  /// The requested target reference. The immutable `@sha256:…` form the registry assigns is only
  /// known once the transfer finishes; follow `operationId`.
  public var reference: String
  /// Local content digest of the image being published.
  public var digest: String
  public var operationId: String?

  public init(reference: String, digest: String, operationId: String?) {
    self.reference = reference
    self.digest = digest
    self.operationId = operationId
  }
}

public struct ImageDeleteRequest: Codable, Sendable, Hashable {
  public var digest: String

  public init(digest: String) { self.digest = digest }
}

public struct ImageDeleteResponse: Codable, Sendable, Hashable {
  public var digest: String

  public init(digest: String) { self.digest = digest }
}

public struct ImagePruneRequest: Codable, Sendable, Hashable {
  /// Report what would be deleted without deleting anything.
  public var dryRun: Bool

  public init(dryRun: Bool = false) { self.dryRun = dryRun }
}

public struct ImagePruneResponse: Codable, Sendable, Hashable {
  /// Images that met the GC rules (spec §110): unpinned, unreferenced, and either stale or, under
  /// `images.cache.maxSize`, evicted to bring the store back under budget.
  public var candidates: [String]
  /// Subset of `candidates` actually removed; always empty when the request set `dryRun`.
  public var deleted: [String]
  /// Images excluded from `candidates` solely because a pin still holds them.
  public var keptPinned: [String]
  public var reclaimedBytes: UInt64
  public var staleStagingRemoved: Int

  public init(
    candidates: [String], deleted: [String], keptPinned: [String], reclaimedBytes: UInt64,
    staleStagingRemoved: Int
  ) {
    self.candidates = candidates
    self.deleted = deleted
    self.keptPinned = keptPinned
    self.reclaimedBytes = reclaimedBytes
    self.staleStagingRemoved = staleStagingRemoved
  }
}

// MARK: - instance.*

public struct InstanceInfoDTO: Codable, Sendable, Hashable {
  public var id: String
  public var name: String
  public var profile: String
  public var imageDigest: String
  public var state: String
  /// `InstanceLifecycle` raw value, as resolved when the instance was created.
  public var lifecycle: String
  /// Last `vmState` the worker reported; `nil` when no worker is connected.
  public var vmState: String?
  public var workerPid: Int32?
  public var workerGeneration: Int
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var diskReservationBytes: UInt64
  public var createdAt: String
  public var startedAt: String?
  /// Set when the guest agent completed its handshake; `nil` while the instance still waits.
  public var agentReadyAt: String?
  public var stoppedAt: String?
  /// The guest's own boot identity, captured at handshake. A change means an unordered reboot.
  public var bootId: String?
  public var tainted: Bool
  public var taintReason: String?
  /// Jobs this VM has run, and the epoch of the last `agent.cleanup` (spec §9.2, §126).
  public var jobsConsumed: Int
  /// Armed by a taint on a busy VM or by a profile image update; the VM goes when its job ends.
  public var retireAfterSession: Bool
  public var failureCode: String?
  public var failureMessage: String?

  public init(
    id: String, name: String, profile: String, imageDigest: String, state: String,
    lifecycle: String = "ephemeral", vmState: String? = nil, workerPid: Int32? = nil,
    workerGeneration: Int, cpuCount: Int,
    memoryBytes: UInt64, diskBytes: UInt64, diskReservationBytes: UInt64, createdAt: String,
    startedAt: String? = nil, agentReadyAt: String? = nil, stoppedAt: String? = nil,
    bootId: String? = nil, tainted: Bool = false, taintReason: String? = nil,
    jobsConsumed: Int = 0, retireAfterSession: Bool = false,
    failureCode: String? = nil, failureMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.profile = profile
    self.imageDigest = imageDigest
    self.state = state
    self.lifecycle = lifecycle
    self.vmState = vmState
    self.workerPid = workerPid
    self.workerGeneration = workerGeneration
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.diskReservationBytes = diskReservationBytes
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.agentReadyAt = agentReadyAt
    self.stoppedAt = stoppedAt
    self.bootId = bootId
    self.tainted = tainted
    self.taintReason = taintReason
    self.jobsConsumed = jobsConsumed
    self.retireAfterSession = retireAfterSession
    self.failureCode = failureCode
    self.failureMessage = failureMessage
  }
}

public struct InstanceListResponse: Codable, Sendable, Hashable {
  public var instances: [InstanceInfoDTO]

  public init(instances: [InstanceInfoDTO]) { self.instances = instances }
}

public struct InstanceCreateRequest: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}

public struct InstanceGetRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

public struct InstanceStopRequest: Codable, Sendable, Hashable {
  public var id: String
  /// Skip the ACPI request and pull the plug.
  public var force: Bool

  public init(id: String, force: Bool = false) {
    self.id = id
    self.force = force
  }
}

public struct InstanceDeleteRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

/// Spec §126 manual taint. A tainted VM never returns to `idle`: an idle one is recycled at once,
/// a busy one the moment its job ends.
public struct InstanceTaintRequest: Codable, Sendable, Hashable {
  public var id: String
  /// Free text recorded in `instances.taint_reason`; `TaintReason` holds the codes runnerd uses.
  public var reason: String

  public init(id: String, reason: String) {
    self.id = id
    self.reason = reason
  }
}
