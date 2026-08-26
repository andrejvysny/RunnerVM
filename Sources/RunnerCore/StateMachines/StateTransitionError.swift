import Foundation

/// Thrown by every `transitioned(to:)`. Carries raw values so it can cross module and RPC
/// boundaries without generics over the specific state enum.
public struct StateTransitionError: Error, Hashable, Sendable, CustomStringConvertible {
  public let machine: String
  public let from: String
  public let to: String

  public init(machine: String, from: String, to: String) {
    self.machine = machine
    self.from = from
    self.to = to
  }

  public var description: String { "illegal \(machine) transition \(from) -> \(to)" }
}

extension StateTransitionError: RunnerError {
  public var code: String { "STATE_TRANSITION_ILLEGAL" }
  public var message: String { description }
  public var retryable: Bool { false }
}

/// Shared shape of the three persisted state machines (spec §46, §47, host mode).
public protocol StateMachineState: RawRepresentable, Hashable, Sendable, CaseIterable, Codable
  where RawValue == String {
  /// Name used in `StateTransitionError`.
  static var machineName: String { get }
  /// Every legal successor. Any edge not listed is illegal.
  var allowedTransitions: Set<Self> { get }
}

extension StateMachineState {
  public func canTransition(to target: Self) -> Bool { allowedTransitions.contains(target) }

  public var isTerminal: Bool { allowedTransitions.isEmpty }

  public func transitioned(to target: Self) throws -> Self {
    guard canTransition(to: target) else {
      throw StateTransitionError(machine: Self.machineName, from: rawValue, to: target.rawValue)
    }
    return target
  }
}
