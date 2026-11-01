import Foundation
import RunnerCore

/// Refusals of the `fleet.*` methods (`Proto/fleet.md`). The GitLab plugin branches on `code`.
public enum FleetError: RunnerError {
  case profileNotGitLab(name: String)
  case leaseInvalid(leaseMs: Int64, minimumMs: Int64, maximumMs: Int64)
  case instanceNotFound(id: String)
  case instanceNotFleet(id: String)
  case instanceNotReady(id: String, state: String)
  /// `reason` names the rule broken, never the key itself.
  case invalidPublicKey(reason: String)
  case noAddress(id: String)
  /// `exitCode` of the guest-side install script; the key is deliberately not part of the error.
  case keyInstallFailed(id: String, exitCode: Int32)
  /// A macOS fleet VM is reached only over ssh, so an image that does not declare it is refused.
  case imageNoSSH

  public var code: String {
    switch self {
    case .profileNotGitLab: "FLEET_PROFILE_NOT_GITLAB"
    case .leaseInvalid: "FLEET_LEASE_INVALID"
    case .instanceNotFound: "FLEET_INSTANCE_NOT_FOUND"
    case .instanceNotFleet: "FLEET_INSTANCE_NOT_FLEET"
    case .instanceNotReady: "FLEET_INSTANCE_NOT_READY"
    case .invalidPublicKey: "FLEET_INVALID_PUBLIC_KEY"
    case .noAddress: "FLEET_NO_ADDRESS"
    case .keyInstallFailed: "FLEET_KEY_INSTALL_FAILED"
    case .imageNoSSH: "FLEET_IMAGE_NO_SSH"
    }
  }

  public var message: String {
    switch self {
    case let .profileNotGitLab(name):
      "profile '\(name)' is not a gitlab profile; fleet.* serves only provider: gitlab"
    case let .leaseInvalid(lease, minimum, maximum):
      "lease \(lease)ms is outside \(minimum)ms...\(maximum)ms"
    case let .instanceNotFound(id): "instance '\(id)' not found"
    case let .instanceNotFleet(id): "instance \(id) is not a fleet instance"
    case let .instanceNotReady(id, state):
      "instance \(id) is '\(state)'; fleet.connect needs 'idle'"
    case let .invalidPublicKey(reason): "invalid public key: \(reason)"
    case let .noAddress(id): "instance \(id) reports no usable guest address"
    case let .keyInstallFailed(id, exitCode):
      "installing the ssh key in instance \(id) failed with exit code \(exitCode)"
    case .imageNoSSH:
      "the macOS image does not declare capabilities.ssh; a fleet VM cannot be reached without it"
    }
  }

  /// Not-ready clears once the guest finishes booting; the plugin retries on it.
  public var retryable: Bool {
    switch self {
    case .instanceNotReady, .noAddress: true
    default: false
    }
  }
}
