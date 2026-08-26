import Foundation

/// Operator-controlled host availability. `draining` advertises capacity 0 to GitHub but lets
/// in-flight jobs finish (spec §109).
public enum HostMode: String, StateMachineState {
  case normal
  case draining
  case offline

  public static let machineName = "HostMode"

  /// Strict cycle from `docs/state_machines.md`: a drain must complete (reach `offline`) before the
  /// host can be readmitted, so there is deliberately no `draining -> normal` shortcut.
  public var allowedTransitions: Set<HostMode> {
    switch self {
    case .normal: [.draining]
    case .draining: [.offline, .normal]  // operators may cancel a drain
    case .offline: [.normal]
    }
  }

  /// `draining` keeps existing jobs but advertises zero capacity.
  public var advertisesCapacity: Bool { self == .normal }

  public var admitsNewWork: Bool { self == .normal }
}
