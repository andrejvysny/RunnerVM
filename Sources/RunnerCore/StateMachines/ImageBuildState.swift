import Foundation

/// Persisted in-daemon image build lifecycle (Phase 4/5 image builder). Mirrors `InstanceState`'s
/// shape: a forward-only chain, with every non-terminal state able to fail or be cancelled.
public enum ImageBuildState: String, StateMachineState {
  case queued
  case resolving
  case staging
  case booting
  case provisioning
  case sealing
  case succeeded
  case failed
  case cancelled

  public static let machineName = "ImageBuildState"

  public var allowedTransitions: Set<ImageBuildState> {
    switch self {
    case .queued: [.resolving, .failed, .cancelled]
    case .resolving: [.staging, .failed, .cancelled]
    case .staging: [.booting, .failed, .cancelled]
    case .booting: [.provisioning, .failed, .cancelled]
    case .provisioning: [.sealing, .failed, .cancelled]
    case .sealing: [.succeeded, .failed, .cancelled]
    case .succeeded, .failed, .cancelled: []
    }
  }

  /// Held against the build concurrency budget until the build reaches a terminal state, mirroring
  /// `InstanceState.consumesCapacity`.
  public var consumesCapacity: Bool { !isTerminal }

  /// States in which a build VM is expected to be running and reachable over vsock.
  public var hasRunningVM: Bool {
    switch self {
    case .booting, .provisioning, .sealing: true
    default: false
    }
  }
}
