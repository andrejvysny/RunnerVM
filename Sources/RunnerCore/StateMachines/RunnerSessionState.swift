import Foundation

/// GitHub runner lifecycle, deliberately separate from the VM lifecycle (spec §47).
public enum RunnerSessionState: String, StateMachineState {
  case planned
  case jitRequested
  case jitIssued
  case jitDelivered
  case runnerStarting
  case runnerOnline
  case jobRunning
  case completed
  case jitFailed
  case runnerStartFailed
  case runnerLost
  case jobInterrupted
  case timedOut

  public static let machineName = "RunnerSessionState"

  public var allowedTransitions: Set<RunnerSessionState> {
    switch self {
    case .planned: [.jitRequested, .jitFailed]
    case .jitRequested: [.jitIssued, .jitFailed]
    case .jitIssued: [.jitDelivered, .runnerStartFailed, .jobInterrupted]
    case .jitDelivered: [.runnerStarting, .runnerStartFailed]
    case .runnerStarting: [.runnerOnline, .runnerStartFailed, .timedOut, .runnerLost]
    // `completed` here covers a runner that exited without ever picking up a job.
    case .runnerOnline: [.jobRunning, .timedOut, .runnerLost, .completed]
    case .jobRunning: [.completed, .jobInterrupted, .runnerLost, .timedOut]
    case .completed, .jitFailed, .runnerStartFailed, .runnerLost, .jobInterrupted, .timedOut: []
    }
  }

  /// Every non-`completed` terminal state schedules `ensureRunnerRemoved(githubRunnerId)`; a JIT
  /// runner that GitHub still believes exists would keep receiving jobs no VM will ever run.
  public var requiresRunnerRemoval: Bool { isTerminal && self != .completed }
}
