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
  var name: String?
  var recipe: Recipe
  var plan: RecipePlan
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

  var hasContext: Bool { packed != nil }
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
