import Foundation

/// In-daemon image build failures (Phase 4/5 image builder): recipe/context intake, base image
/// verification, step execution and sealing. Mirrors `ImageError`'s shape.
public enum ImageBuildError: RunnerError {
  case recipeUnreadable(path: String, uid: uid_t)
  case contextUnreadable(path: String)
  case contextTooLarge(bytes: UInt64, limit: UInt64, largest: [String])
  case contextUnsafeEntry(path: String, reason: String)
  case baseUnverified
  case baseDigestMismatch(expected: String, actual: String)
  case baseNotPartitioned
  case baseFormatUnsupported(reason: String)
  case baseNoGuestAgent(reference: String)
  case guestAgentMissing(tried: [String])
  /// No `provision-macos-tart.sh` (or no darwin guest agent) at any of the candidate locations.
  case macosScriptMissing(what: String, tried: [String])
  /// The provisioning script ran to completion but its result JSON says the guest is not sealable.
  case macosProvisionFailed(reason: String)
  /// The provisioning VM never appeared in `/var/db/dhcpd_leases`, so the host has no address to
  /// drive it at.
  case macosLeaseNotFound(macAddress: String, seconds: Int)
  /// The guest was asked to halt itself and the VM was still running when the wait ran out.
  case macosGuestDidNotStop(seconds: Int)
  /// The sealed candidate failed its cold-boot qualification. The managed alias is untouched.
  case macosQualificationFailed(reason: String)
  case stepFailed(step: Int, line: String, exitCode: Int32, tail: String)
  case stepTimeout(step: Int)
  case stepOutputTooLarge(step: Int)
  case timeout
  case agentUnreachable(reason: String)
  case imageNotReady(reasons: [String])
  case probeFailed
  case sealFailed(reason: String)
  case cancelled
  case interrupted
  /// Restart recovery could not prove the builder worker dead before the recovery deadline, so the
  /// row was abandoned: the pin is released but the build directory is left to the live process.
  case recoveryAbandoned
  /// A `build cancel` on a row this daemon does not own, whose builder worker could not be proven
  /// dead. Releasing anything here would race a VM that is still writing (B8).
  case buildWorkerUnverifiable(buildId: String, reason: String)
  /// A build argument whose value has the shape of a credential. Arguments are persisted,
  /// written into provenance and pushed with the image; they are never secrets.
  case argumentLooksLikeSecret(key: String)
  case notFound(id: String)
  case nameRequired
  case atMaxConcurrent(limit: Int)
  case tooManySteps(count: Int, limit: Int)
  case toolMissing(tool: String)
  case runnerVersionUnresolved
  case runnerDigestUnavailable(version: String)
  case runnerDigestMismatch
  case insufficientDisk(needed: UInt64, free: UInt64)
  case notCancellable(state: String)
  /// No `ImageBuildService` is wired into the daemon yet (Phase 5 lands the builder itself).
  case unavailable

  public var code: String {
    switch self {
    case .recipeUnreadable: "BUILD_RECIPE_UNREADABLE"
    case .contextUnreadable: "BUILD_CONTEXT_UNREADABLE"
    case .contextTooLarge: "BUILD_CONTEXT_TOO_LARGE"
    case .contextUnsafeEntry: "BUILD_CONTEXT_UNSAFE_ENTRY"
    case .baseUnverified: "BUILD_BASE_UNVERIFIED"
    case .baseDigestMismatch: "BUILD_BASE_DIGEST_MISMATCH"
    case .baseNotPartitioned: "BUILD_BASE_NOT_PARTITIONED"
    case .baseFormatUnsupported: "BUILD_BASE_FORMAT_UNSUPPORTED"
    case .baseNoGuestAgent: "BUILD_BASE_NO_GUEST_AGENT"
    case .guestAgentMissing: "BUILD_GUEST_AGENT_MISSING"
    case .macosScriptMissing: "BUILD_MACOS_SCRIPT_MISSING"
    case .macosProvisionFailed: "BUILD_MACOS_PROVISION_FAILED"
    case .macosLeaseNotFound: "BUILD_MACOS_LEASE_NOT_FOUND"
    case .macosGuestDidNotStop: "BUILD_MACOS_GUEST_DID_NOT_STOP"
    case .macosQualificationFailed: "BUILD_MACOS_QUALIFICATION_FAILED"
    case .stepFailed: "BUILD_STEP_FAILED"
    case .stepTimeout: "BUILD_STEP_TIMEOUT"
    case .stepOutputTooLarge: "BUILD_STEP_OUTPUT_TOO_LARGE"
    case .timeout: "BUILD_TIMEOUT"
    case .agentUnreachable: "BUILD_AGENT_UNREACHABLE"
    case .imageNotReady: "BUILD_IMAGE_NOT_READY"
    case .probeFailed: "BUILD_PROBE_FAILED"
    case .sealFailed: "BUILD_SEAL_FAILED"
    case .cancelled: "BUILD_CANCELLED"
    case .interrupted: "BUILD_INTERRUPTED"
    case .recoveryAbandoned: "BUILD_RECOVERY_ABANDONED"
    case .buildWorkerUnverifiable: "BUILD_WORKER_UNVERIFIABLE"
    case .argumentLooksLikeSecret: "BUILD_ARG_LOOKS_LIKE_SECRET"
    case .notFound: "BUILD_NOT_FOUND"
    case .nameRequired: "BUILD_NAME_REQUIRED"
    case .atMaxConcurrent: "BUILD_AT_MAX_CONCURRENT"
    case .tooManySteps: "BUILD_TOO_MANY_STEPS"
    case .toolMissing: "BUILD_TOOL_MISSING"
    case .runnerVersionUnresolved: "BUILD_RUNNER_VERSION_UNRESOLVED"
    case .runnerDigestUnavailable: "BUILD_RUNNER_DIGEST_UNAVAILABLE"
    case .runnerDigestMismatch: "BUILD_RUNNER_DIGEST_MISMATCH"
    case .insufficientDisk: "BUILD_INSUFFICIENT_DISK"
    case .notCancellable: "BUILD_NOT_CANCELLABLE"
    case .unavailable: "BUILD_UNAVAILABLE"
    }
  }

  public var message: String {
    switch self {
    case let .recipeUnreadable(path, uid): "recipe at \(path) is not readable by uid \(uid)"
    case let .contextUnreadable(path): "build context at \(path) is not readable"
    case let .contextTooLarge(bytes, limit, largest):
      "build context is \(ByteSize(bytes: bytes)), exceeding the \(ByteSize(bytes: limit)) limit "
        + "(largest entries: \(largest.joined(separator: ", ")))"
    case let .contextUnsafeEntry(path, reason): "build context entry '\(path)' is unsafe: \(reason)"
    case .baseUnverified: "base image could not be verified before use"
    case let .baseDigestMismatch(expected, actual):
      "base image digest mismatch: expected \(expected), got \(actual)"
    case .baseNotPartitioned: "base image disk has no recognizable partition table"
    case let .baseFormatUnsupported(reason): "base image format is unsupported: \(reason)"
    case let .baseNoGuestAgent(reference): "base image \(reference) carries no RunnerVM guest agent"
    case let .guestAgentMissing(tried):
      "no guest agent binary found (tried: \(tried.joined(separator: ", ")))"
    case let .macosScriptMissing(what, tried):
      "no \(what) found (tried: \(tried.joined(separator: ", ")))"
    case let .macosProvisionFailed(reason): "macOS guest provisioning failed: \(reason)"
    case let .macosLeaseNotFound(macAddress, seconds):
      "no DHCP lease for \(macAddress) in /var/db/dhcpd_leases after \(seconds)s; the "
        + "provisioning guest never brought its network up"
    case let .macosGuestDidNotStop(seconds):
      "the provisioning guest was still running \(seconds)s after it was told to halt"
    case let .macosQualificationFailed(reason):
      "the sealed macOS image failed its cold-boot qualification: \(reason)"
    case let .stepFailed(step, line, exitCode, tail):
      "step \(step) (\(line)) exited \(exitCode): \(tail)"
    case let .stepTimeout(step): "step \(step) timed out"
    case let .stepOutputTooLarge(step): "step \(step) produced more output than the log limit allows"
    case .timeout: "build timed out"
    case let .agentUnreachable(reason): "guest agent unreachable: \(reason)"
    case let .imageNotReady(reasons): "image is not ready to seal: \(reasons.joined(separator: ", "))"
    case .probeFailed: "post-build readiness probe failed"
    case let .sealFailed(reason): "sealing the built image failed: \(reason)"
    case .cancelled: "build was cancelled"
    case .interrupted: "build was interrupted (daemon restarted mid-build)"
    case .recoveryAbandoned:
      "build abandoned: its builder worker could not be proven dead before the recovery deadline; "
        + "the build directory was left in place for the live process"
    case let .buildWorkerUnverifiable(buildId, reason):
      "build \(buildId) still has a builder worker that cannot be proven dead (\(reason)); "
        + "nothing was released -- check `runnerd`'s log and the build's vmworker before retrying"
    case let .argumentLooksLikeSecret(key):
      "build argument \(key) looks like a credential; build arguments are recorded in the build "
        + "row, the image provenance and any pushed OCI config and are never secrets"
    case let .notFound(id): "build \(id) not found"
    case .nameRequired: "a build name is required to push or alias the result"
    case let .atMaxConcurrent(limit): "at most \(limit) build(s) may run concurrently"
    case let .tooManySteps(count, limit):
      "the recipe plans \(count) steps, more than the \(limit) `build.maxSteps` allows"
    case let .toolMissing(tool): "required tool '\(tool)' is not available on this host"
    case .runnerVersionUnresolved: "could not resolve the actions/runner version to bake in"
    case let .runnerDigestUnavailable(version): "no digest available for actions/runner \(version)"
    case .runnerDigestMismatch: "downloaded actions/runner did not match its expected digest"
    case let .insufficientDisk(needed, free):
      "needs \(ByteSize(bytes: needed)), only \(ByteSize(bytes: free)) free"
    case let .notCancellable(state): "build in state \(state) cannot be cancelled"
    case .unavailable: "the image builder is not available on this daemon"
    }
  }

  public var retryable: Bool {
    switch self {
    case .agentUnreachable, .probeFailed, .atMaxConcurrent, .insufficientDisk, .timeout,
         .stepTimeout, .interrupted, .recoveryAbandoned, .buildWorkerUnverifiable,
         .macosLeaseNotFound, .macosGuestDidNotStop:
      true
    case .recipeUnreadable, .contextUnreadable, .contextTooLarge, .contextUnsafeEntry,
         .baseUnverified, .baseDigestMismatch, .baseNotPartitioned, .baseFormatUnsupported,
         .baseNoGuestAgent, .guestAgentMissing, .stepFailed, .stepOutputTooLarge, .imageNotReady,
         .sealFailed, .cancelled, .notFound, .nameRequired, .toolMissing, .tooManySteps,
         .runnerVersionUnresolved, .runnerDigestUnavailable, .runnerDigestMismatch,
         .notCancellable, .unavailable, .argumentLooksLikeSecret, .macosScriptMissing,
         .macosProvisionFailed, .macosQualificationFailed:
      false
    }
  }
}
