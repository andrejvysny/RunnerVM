import Foundation

/// Persisted managed-image lifecycle (`managed_images.state`, `docs/db_schema_v4.sql`). Unlike
/// `ImageBuildState`, this machine has no terminal state: `failed` recovers back to `checking` or
/// `idle` rather than ending the row's life, since a managed image keeps being re-checked forever.
public enum ManagedImageState: String, StateMachineState {
  case idle
  case checking
  case downloading
  case building
  case qualifying
  case promoting
  case failed

  public static let machineName = "ManagedImageState"

  public var allowedTransitions: Set<ManagedImageState> {
    switch self {
    case .idle: [.checking, .failed]
    case .checking: [.idle, .downloading, .building, .failed]
    case .downloading: [.qualifying, .failed]
    case .building: [.qualifying, .failed]
    case .qualifying: [.promoting, .failed]
    case .promoting: [.idle, .failed]
    case .failed: [.checking, .idle]
    }
  }
}
