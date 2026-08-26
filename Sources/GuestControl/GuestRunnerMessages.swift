import Foundation

// MARK: - agent.startRunner

/// `agent.startRunner` payload.
///
/// `jitConfig` is a GitHub JIT runner configuration: a bearer-equivalent secret. The agent passes
/// it to the runner through `ACTIONS_RUNNER_INPUT_JITCONFIG` and zeroes it after the spawn. The
/// custom `description`/`debugDescription` below exist so that an accidental interpolation of this
/// value into a log line, an error message or a crash report cannot leak it — the synthesized
/// reflection would otherwise print every stored property.
public struct StartRunnerRequest: Codable, Sendable, Equatable {
  public var sessionId: String
  public var jitConfig: String
  public var workDir: String?
  public var env: [String: String]?
  public var labels: [String]?

  public init(
    sessionId: String, jitConfig: String, workDir: String? = nil, env: [String: String]? = nil,
    labels: [String]? = nil
  ) {
    self.sessionId = sessionId
    self.jitConfig = jitConfig
    self.workDir = workDir
    self.env = env
    self.labels = labels
  }
}

extension StartRunnerRequest: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "StartRunnerRequest(sessionId: \(sessionId), workDir: \(workDir ?? "-"), "
      + "envKeys: \(env?.keys.sorted() ?? []), labels: \(labels ?? []), jitConfig: <redacted>)"
  }

  public var debugDescription: String { description }
}

/// `agent.startRunner` result. `startedAt` is RFC 3339 UTC, as the agent formats it.
public struct StartRunnerResponse: Codable, Sendable, Equatable {
  public var pid: Int64
  public var startedAt: String

  public init(pid: Int64, startedAt: String) {
    self.pid = pid
    self.startedAt = startedAt
  }

  public var startedAtDate: Date? { GuestCoding.date(from: startedAt) }
}

// MARK: - agent.runnerStatus

public enum RunnerProcessState: String, Codable, Sendable, CaseIterable, Hashable {
  case starting
  case online
  case busy
  case exited
  case unknown
}

public struct RunnerStatusRequest: Codable, Sendable, Equatable {
  public var sessionId: String

  public init(sessionId: String) { self.sessionId = sessionId }
}

/// `agent.runnerStatus` result. `pid` is absent when no process is known; `exitCode`/`exitedAt`
/// appear only in state `exited`.
public struct RunnerStatus: Codable, Sendable, Equatable {
  public var state: RunnerProcessState
  public var pid: Int64?
  public var exitCode: Int64?
  public var exitedAt: String?

  public init(
    state: RunnerProcessState, pid: Int64? = nil, exitCode: Int64? = nil, exitedAt: String? = nil
  ) {
    self.state = state
    self.pid = pid
    self.exitCode = exitCode
    self.exitedAt = exitedAt
  }

  public var exitedAtDate: Date? { exitedAt.flatMap(GuestCoding.date(from:)) }
}

// MARK: - agent.stopRunner

/// `graceMs` is the delay between SIGTERM and SIGKILL of the runner's process group.
public struct StopRunnerRequest: Codable, Sendable, Equatable {
  public var sessionId: String
  public var graceMs: Int64

  public init(sessionId: String, graceMs: Int64) {
    self.sessionId = sessionId
    self.graceMs = graceMs
  }
}

public struct StopRunnerResponse: Codable, Sendable, Equatable {
  public var stopped: Bool

  public init(stopped: Bool) { self.stopped = stopped }
}

// MARK: - agent.cleanup

/// `epoch` is monotonic per VM; replaying an epoch is a no-op on the agent.
public struct CleanupRequest: Codable, Sendable, Equatable {
  public var epoch: Int64

  public init(epoch: Int64) { self.epoch = epoch }
}

public struct CleanupResponse: Codable, Sendable, Equatable {
  public var ok: Bool
  public var removed: [String]

  public init(ok: Bool, removed: [String] = []) {
    self.ok = ok
    self.removed = removed
  }
}
