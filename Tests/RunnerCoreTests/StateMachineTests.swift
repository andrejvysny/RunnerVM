import Foundation
import RunnerCore
import Testing

/// The expected adjacency below is transcribed by hand from `docs/state_machines.md` so the tests
/// fail if the implementation drifts from the document, not merely if it is self-consistent.
@Suite struct InstanceStateTests {
  static let expected: [InstanceState: Set<InstanceState>] = [
    .planned: [.preparing, .failed, .deleting],
    .preparing: [.cloning, .failed, .deleting],
    .cloning: [.startingWorker, .failed, .deleting],
    .startingWorker: [.startingVM, .failed, .interrupted, .deleting],
    .startingVM: [.waitingForAgent, .failed, .interrupted, .deleting],
    .waitingForAgent: [.idle, .failed, .interrupted, .stopping],
    .idle: [.configuringRunner, .stopping, .interrupted, .deleting],
    .configuringRunner: [.runnerStarting, .stopping, .interrupted],
    .runnerStarting: [.runnerOnline, .stopping, .interrupted],
    .runnerOnline: [.busy, .stopping, .interrupted],
    .busy: [.cleaning, .stopping, .interrupted],
    .cleaning: [.idle, .stopping, .interrupted],
    .stopping: [.deleting, .stopped, .interrupted],
    .stopped: [.deleting, .startingWorker],
    .interrupted: [.deleting, .startingWorker],
    .failed: [.deleting],
    .orphaned: [.deleting],
    .deleting: [.deleted],
    .deleted: [],
  ]

  @Test func everyStateHasAnExpectedRow() {
    #expect(Set(Self.expected.keys) == Set(InstanceState.allCases))
    #expect(InstanceState.allCases.count == 19)
  }

  @Test func everyOrderedPairMatchesTheTable() throws {
    for from in InstanceState.allCases {
      let allowed = try #require(Self.expected[from])
      for to in InstanceState.allCases {
        #expect(from.canTransition(to: to) == allowed.contains(to), "\(from) -> \(to)")
      }
    }
  }

  @Test func transitionedReturnsTargetOrThrows() throws {
    #expect(try InstanceState.planned.transitioned(to: .preparing) == .preparing)
    #expect(throws: StateTransitionError(
      machine: "InstanceState", from: "planned", to: "idle"
    )) {
      _ = try InstanceState.planned.transitioned(to: .idle)
    }
  }

  @Test func selfTransitionsAreAlwaysIllegal() {
    for state in InstanceState.allCases {
      #expect(!state.canTransition(to: state), "\(state)")
    }
  }

  @Test func onlyDeletedIsTerminal() {
    #expect(InstanceState.allCases.filter(\.isTerminal) == [.deleted])
  }

  @Test func everyStateExceptDeletedConsumesCapacity() {
    for state in InstanceState.allCases {
      #expect(state.consumesCapacity == (state != .deleted), "\(state)")
    }
  }

  @Test func runningVMStatesCoverTheGuestLifetime() {
    #expect(InstanceState.idle.hasRunningVM)
    #expect(InstanceState.busy.hasRunningVM)
    #expect(!InstanceState.planned.hasRunningVM)
    #expect(!InstanceState.stopped.hasRunningVM)
    #expect(!InstanceState.deleted.hasRunningVM)
  }

  @Test func rawValuesMatchTheDocument() {
    #expect(InstanceState.startingVM.rawValue == "startingVM")
    #expect(InstanceState.waitingForAgent.rawValue == "waitingForAgent")
    #expect(InstanceState.configuringRunner.rawValue == "configuringRunner")
    #expect(InstanceState(rawValue: "runnerOnline") == .runnerOnline)
  }

  @Test func everyStateIsReachableFromPlannedOrIsAnEntryPoint() {
    var reachable: Set<InstanceState> = [.planned]
    var frontier: Set<InstanceState> = [.planned]
    while let next = frontier.popFirst() {
      for target in next.allowedTransitions where reachable.insert(target).inserted {
        frontier.insert(target)
      }
    }
    // `orphaned` is only ever entered by the reconciler, never by a transition.
    #expect(Set(InstanceState.allCases).subtracting(reachable) == [.orphaned])
  }
}

@Suite struct RunnerSessionStateTests {
  static let expected: [RunnerSessionState: Set<RunnerSessionState>] = [
    .planned: [.jitRequested, .jitFailed],
    .jitRequested: [.jitIssued, .jitFailed],
    .jitIssued: [.jitDelivered, .runnerStartFailed, .jobInterrupted],
    .jitDelivered: [.runnerStarting, .runnerStartFailed],
    .runnerStarting: [.runnerOnline, .runnerStartFailed, .timedOut, .runnerLost],
    .runnerOnline: [.jobRunning, .timedOut, .runnerLost, .completed],
    .jobRunning: [.completed, .jobInterrupted, .runnerLost, .timedOut],
    .completed: [],
    .jitFailed: [],
    .runnerStartFailed: [],
    .runnerLost: [],
    .jobInterrupted: [],
    .timedOut: [],
  ]

  @Test func everyStateHasAnExpectedRow() {
    #expect(Set(Self.expected.keys) == Set(RunnerSessionState.allCases))
    #expect(RunnerSessionState.allCases.count == 13)
  }

  @Test func everyOrderedPairMatchesTheTable() throws {
    for from in RunnerSessionState.allCases {
      let allowed = try #require(Self.expected[from])
      for to in RunnerSessionState.allCases {
        #expect(from.canTransition(to: to) == allowed.contains(to), "\(from) -> \(to)")
      }
    }
  }

  @Test func terminalStatesMatchTheDocument() {
    #expect(Set(RunnerSessionState.allCases.filter(\.isTerminal)) == [
      .completed, .jitFailed, .runnerStartFailed, .runnerLost, .jobInterrupted, .timedOut,
    ])
  }

  @Test func everyNonCompletedTerminalRequiresRunnerRemoval() {
    for state in RunnerSessionState.allCases {
      #expect(state.requiresRunnerRemoval == (state.isTerminal && state != .completed), "\(state)")
    }
    #expect(!RunnerSessionState.completed.requiresRunnerRemoval)
    #expect(!RunnerSessionState.jobRunning.requiresRunnerRemoval)
  }

  @Test func happyPathWalks() throws {
    var state = RunnerSessionState.planned
    for next in [RunnerSessionState.jitRequested, .jitIssued, .jitDelivered, .runnerStarting,
                 .runnerOnline, .jobRunning, .completed] {
      state = try state.transitioned(to: next)
    }
    #expect(state == .completed)
  }

  @Test func illegalTransitionThrowsWithBothEndpoints() {
    #expect { _ = try RunnerSessionState.planned.transitioned(to: .jobRunning) } throws: { error in
      guard let error = error as? StateTransitionError else { return false }
      return error.from == "planned" && error.to == "jobRunning"
        && error.machine == "RunnerSessionState" && error.code == "STATE_TRANSITION_ILLEGAL"
        && !error.retryable
    }
  }
}

@Suite struct HostModeTests {
  static let expected: [HostMode: Set<HostMode>] = [
    .normal: [.draining],
    .draining: [.offline, .normal],
    .offline: [.normal],
  ]

  @Test func everyOrderedPairMatchesTheTable() throws {
    #expect(Set(Self.expected.keys) == Set(HostMode.allCases))
    for from in HostMode.allCases {
      let allowed = try #require(Self.expected[from])
      for to in HostMode.allCases {
        #expect(from.canTransition(to: to) == allowed.contains(to), "\(from) -> \(to)")
      }
    }
  }

  @Test func drainingKeepsJobsButAdvertisesNoCapacity() {
    #expect(HostMode.normal.advertisesCapacity)
    #expect(!HostMode.draining.advertisesCapacity)
    #expect(!HostMode.draining.admitsNewWork)
    #expect(!HostMode.offline.admitsNewWork)
  }

  @Test func noHostModeIsTerminal() {
    #expect(HostMode.allCases.allSatisfy { !$0.isTerminal })
  }

  @Test func cannotSkipDrainingButCanCancelIt() {
    #expect(!HostMode.normal.canTransition(to: .offline))
    #expect(HostMode.draining.canTransition(to: .normal))
  }
}
