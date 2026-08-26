import Foundation

/// Image resolution, pull, cache and clone failures.
public enum ImageError: RunnerError {
  case referenceInvalid(reference: String)
  case notFound(reference: String)
  case pullFailed(reference: String, cause: (any Error & Sendable)?)
  case pullTimeout(reference: String)
  case digestMismatch(expected: String, actual: String)
  case manifestUnsupported(reason: String)
  case metadataInvalid(reason: String)
  case incompatibleHost(reason: String)
  case incompatibleGuestOS(expected: GuestOS, actual: GuestOS)
  case diskSmallerThanImage(requestedBytes: UInt64, imageBytes: UInt64)
  case cloneFailed(reason: String)
  case cloneUnsupported(path: String)
  case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
  case stillPinned(digest: ImageDigest)
  case runnerTooOld(digest: ImageDigest, imageVersion: String?, latestVersion: String)

  public var code: String {
    switch self {
    case .referenceInvalid: "IMAGE_REFERENCE_INVALID"
    case .notFound: "IMAGE_NOT_FOUND"
    case .pullFailed: "IMAGE_PULL_FAILED"
    case .pullTimeout: "IMAGE_PULL_TIMEOUT"
    case .digestMismatch: "IMAGE_DIGEST_MISMATCH"
    case .manifestUnsupported: "IMAGE_MANIFEST_UNSUPPORTED"
    case .metadataInvalid: "IMAGE_METADATA_INVALID"
    case .incompatibleHost: "IMAGE_INCOMPATIBLE_HOST"
    case .incompatibleGuestOS: "IMAGE_INCOMPATIBLE_GUEST_OS"
    case .diskSmallerThanImage: "IMAGE_DISK_SMALLER_THAN_IMAGE"
    case .cloneFailed: "IMAGE_CLONE_FAILED"
    case .cloneUnsupported: "IMAGE_CLONE_UNSUPPORTED"
    case .insufficientDiskSpace: "IMAGE_INSUFFICIENT_DISK_SPACE"
    case .stillPinned: "IMAGE_STILL_PINNED"
    case .runnerTooOld: "IMAGE_RUNNER_TOO_OLD"
    }
  }

  public var message: String {
    switch self {
    case .referenceInvalid(let reference): "invalid image reference '\(reference)'"
    case .notFound(let reference): "image not found: \(reference)"
    case .pullFailed(let reference, _): "pull failed for \(reference)"
    case .pullTimeout(let reference): "pull timed out for \(reference)"
    case .digestMismatch(let expected, let actual): "digest mismatch: expected \(expected), got \(actual)"
    case .manifestUnsupported(let reason): "unsupported manifest: \(reason)"
    case .metadataInvalid(let reason): "invalid image metadata: \(reason)"
    case .incompatibleHost(let reason): "image is incompatible with this host: \(reason)"
    case .incompatibleGuestOS(let expected, let actual):
      "image is \(actual.rawValue) but the profile declares \(expected.rawValue)"
    case .diskSmallerThanImage(let requested, let image):
      "requested disk \(ByteSize(bytes: requested)) is smaller than image \(ByteSize(bytes: image))"
    case .cloneFailed(let reason): "clone failed: \(reason)"
    case .cloneUnsupported(let path):
      "\(path) is not on a clone-capable (APFS) volume and full copies are disabled"
    case .insufficientDiskSpace(let required, let available):
      "needs \(ByteSize(bytes: required)), only \(ByteSize(bytes: available)) free"
    case .stillPinned(let digest): "image \(digest) is still pinned"
    case .runnerTooOld(let digest, let imageVersion, let latest):
      "image \(digest) has actions/runner \(imageVersion ?? "unknown") but \(latest) has been "
        + "published for more than \(RunnerVersionPolicy.graceDays) days; rebuild the image "
        + "(imageUpdates.denyTooOldRunner is on)"
    }
  }

  public var retryable: Bool {
    switch self {
    case .pullFailed, .pullTimeout, .cloneFailed, .insufficientDiskSpace, .stillPinned:
      true
    case .referenceInvalid, .notFound, .digestMismatch, .manifestUnsupported, .metadataInvalid,
         .incompatibleHost, .incompatibleGuestOS, .diskSmallerThanImage, .cloneUnsupported,
         .runnerTooOld:
      false
    }
  }

  public var underlying: (any Error)? {
    if case .pullFailed(_, let cause) = self { return cause }
    return nil
  }
}
