import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Persistence
import RunnerCore

/// Everything `image.build` settled synchronously, before the RPC answered: the parsed recipe, the
/// resolved plan, the packed context and the resource envelope. Immutable from here on -- a build
/// is defined by what its `start` call saw, not by what the operator's tree looks like later (N2).
struct BuildInput: Sendable {
  var id: ImageBuildID
  /// Which ladder `runStages` runs. A `macosProvision` build has no recipe and no plan: its
  /// "steps" are a host-side script driving a guest over SSH, not `agent.exec` calls.
  var kind: ImageBuildKind = .runnerfile
  var name: String?
  /// `nil` for `.macosProvision`.
  var recipe: Recipe?
  /// `nil` for `.macosProvision`.
  var plan: RecipePlan?
  var contextPath: String
  /// `nil` when the plan has no `COPY`: there is nothing for the guest to mount.
  var packed: PackedContext?
  var args: [String: String]
  var digestSource: String?
  var runnerVersion: String?
  var runnerSHA256: String?
  var runnerSudo: Bool
  var cpuCount: Int
  var memoryBytes: UInt64
  var diskBytes: UInt64
  var reservationBytes: UInt64
  var timeout: Duration
  var stepTimeout: Duration
  var push: String?
  var noCache: Bool
  /// Set for `.macosProvision` and nowhere else.
  var macos: MacOSProvisionInput?

  var hasContext: Bool { packed != nil }
}

/// Everything a managed macOS provisioning build settled before its build row existed: which
/// managed image it is producing, which upstream artifact it starts from, and the two host-side
/// files it will shell out to.
///
/// Resolved synchronously, like a recipe: a missing `provision-macos-tart.sh` or darwin guest
/// agent is a misconfiguration the operator should see as a refusal, not as a build that failed
/// forty minutes later with a VM already booted.
struct MacOSProvisionInput: Sendable {
  /// `images.managed[].name` — the local alias a successful run is promoted to.
  var managedName: String
  /// The upstream Tart reference, e.g. `ghcr.io/cirruslabs/macos-tahoe-base:latest`.
  var sourceReference: String
  /// The upstream *manifest* digest this run is qualifying, when the caller had resolved one.
  var sourceDigest: String?
  var script: URL
  var scriptSHA256: String
  var agentBinary: URL
  /// Keeps the base image's SSH access instead of running the seal-time lockdown. Never set by the
  /// managed launcher; plumbed for a future operator-driven build that wants a diagnosable guest.
  var debugSSH: Bool
}

/// The mutable half of one running build: what has been created so far, so teardown knows exactly
/// what to undo. Only ever touched from the `ImageBuilder` actor, which is why it is a plain class
/// rather than an actor of its own.
final class BuildRun {
  let input: BuildInput
  var state: ImageBuildState = .queued
  var operationId: OperationID?
  var layout: VMBuildLayout?
  var worker: BuilderWorker?
  var agent: GuestAgentClient?
  var log: BuildLogWriter?
  var basePinned = false
  var baseDigest: ImageDigest?
  var baseSHA256: String?
  var baseRawSHA256: String?
  var baseSource: String?
  var probeReport: BuildProbeReport?
  var imageDigest: ImageDigest?
  /// macOS provisioning: the base image's own metadata, carried to the sealed image's.
  var baseImage: ImageInfo?
  /// macOS provisioning: what the host-side script reported.
  var provisionResult: MacOSProvisionResult?
  /// macOS provisioning: the cold-boot qualification VM. A build id of its own, so it gets its own
  /// directory, its own worker socket and — because the directory is new — a machine identifier
  /// vmworker mints from scratch, which is the whole point of qualifying a *clone*.
  var qualifyId: ImageBuildID?
  var qualifyLayout: VMBuildLayout?
  var qualifyWorker: BuilderWorker?
  var qualifyAgent: GuestAgentClient?
  /// Handed from `runStages` to `finish` through the run rather than as an argument: teardown runs
  /// in a fresh, uncancelled task, and `any Error` cannot cross an unstructured task boundary.
  var outcome: Result<ImageDigest, any Error>?
  var startedAt = ContinuousClock.now
  var deadline: ContinuousClock.Instant

  init(input: BuildInput) {
    self.input = input
    deadline = ContinuousClock.now.advanced(by: input.timeout)
  }

  var id: ImageBuildID { input.id }
}

/// The base disk a build clones from, after `resolveBase` decided which of the three `FROM` forms
/// it was.
struct ResolvedBase: Sendable {
  enum Content: Sendable {
    /// An image in the local store; `BuildStore` clones its disk layer.
    case image(ImageDigest, ImageInfo)
    /// A raw disk staged outside the store (a converted cloud image).
    case rawDisk(URL, virtualBytes: UInt64)
  }

  var content: Content
  /// What `spec.json` records as the image identity. A cloud base has no image digest, so its raw
  /// disk's own `sha256:` stands in.
  var specDigest: ImageDigest
  var reference: String
  var source: String?
  var sha256: String?
  var rawSHA256: String?
  /// A bootstrap base has no guest agent yet, so the build seeds cloud-init to install one.
  var needsSeed: Bool

  /// The local image this build derives from, when it derives from one at all. Recorded as the
  /// sealed image's `provenance.parentImageDigest`.
  var imageDigest: ImageDigest? {
    if case let .image(digest, _) = content { return digest }
    return nil
  }
}
