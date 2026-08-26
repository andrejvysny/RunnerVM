import Foundation

/// Persisted VM lifecycle (spec §46, table in `docs/state_machines.md`).
///
/// Lifecycle-conditional edges (`busy -> cleaning` is reusable-only, `stopped -> startingWorker` is a
/// reusable restart) are legal here for both lifecycles: this type knows only states, and the policy
/// that picks the successor lives in the orchestrator. Ambiguity there resolves to
/// `interrupted`, never `idle`.
public enum InstanceState: String, StateMachineState {
  case planned
  case preparing
  case cloning
  case startingWorker
  case startingVM
  case waitingForAgent
  case idle
  case configuringRunner
  case runnerStarting
  case runnerOnline
  case busy
  case cleaning
  case stopping
  case stopped
  case interrupted
  case failed
  /// Entered only by reconciliation when on-disk state has no owning row (spec §111).
  case orphaned
  case deleting
  case deleted

  public static let machineName = "InstanceState"

  public var allowedTransitions: Set<InstanceState> {
    switch self {
    case .planned: [.preparing, .failed, .deleting]
    case .preparing: [.cloning, .failed, .deleting]
    case .cloning: [.startingWorker, .failed, .deleting]
    case .startingWorker: [.startingVM, .failed, .interrupted, .deleting]
    case .startingVM: [.waitingForAgent, .failed, .interrupted, .deleting]
    case .waitingForAgent: [.idle, .failed, .interrupted, .stopping]
    case .idle: [.configuringRunner, .stopping, .interrupted, .deleting]
    case .configuringRunner: [.runnerStarting, .stopping, .interrupted]
    case .runnerStarting: [.runnerOnline, .stopping, .interrupted]
    case .runnerOnline: [.busy, .stopping, .interrupted]
    case .busy: [.cleaning, .stopping, .interrupted]
    case .cleaning: [.idle, .stopping, .interrupted]
    case .stopping: [.deleting, .stopped, .interrupted]
    case .stopped: [.deleting, .startingWorker]
    case .interrupted: [.deleting, .startingWorker]
    case .failed: [.deleting]
    case .orphaned: [.deleting]
    case .deleting: [.deleted]
    case .deleted: []
    }
  }

  /// Reservations are released only after physical deletion, so every other state still holds
  /// cpu/memory/disk against the host budget (plan C1 "Capacity").
  public var consumesCapacity: Bool { self != .deleted }

  /// States in which a guest is expected to be running and reachable over vsock.
  public var hasRunningVM: Bool {
    switch self {
    case .waitingForAgent, .idle, .configuringRunner, .runnerStarting, .runnerOnline, .busy,
         .cleaning, .stopping:
      true
    default:
      false
    }
  }
}
