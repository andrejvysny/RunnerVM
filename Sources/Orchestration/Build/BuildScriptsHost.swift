import Foundation
import GuestControl
import RunnerCore

/// What one `agent.exec` produced, from the host's side of the stream.
public struct StepOutcome: Sendable {
  public var exitCode: Int32
  /// Raw stdout, captured only for steps whose output is parsed (the probe). Empty otherwise, so a
  /// recipe step's gigabyte of `apt` chatter is never held in memory.
  public var stdout: String
  /// Last lines seen, for a failure message. Bounded by `tailLines`.
  public var tail: [String]
}

/// Turns an `agent.exec` event stream into `build.log` lines, under three independent ceilings
/// (B9): the log cap, an idle timeout, and the whole build's deadline.
///
/// The guest is untrusted, and `RPCClient.stream` buffers without bound, so "the agent stopped
/// talking" and "the agent will not stop talking" both have to be host-side failures rather than a
/// wait that never ends.
public enum BuildExecPump {
  public static let tailLines = 40

  public static func run(
    stream: AsyncThrowingStream<ExecEvent, any Error>, log: BuildLogWriter, step: Int,
    capture: Bool, idleTimeout: Duration, deadline: ContinuousClock.Instant,
    pollInterval: Duration = .milliseconds(200)
  ) async throws -> StepOutcome {
    let heartbeat = Heartbeat()
    return try await withThrowingTaskGroup(of: StepOutcome?.self) { group in
      group.addTask {
        try await consume(
          stream: stream, log: log, step: step, capture: capture, heartbeat: heartbeat)
      }
      group.addTask {
        try await watch(
          heartbeat: heartbeat, step: step, idleTimeout: idleTimeout, deadline: deadline,
          pollInterval: pollInterval)
        return nil
      }
      while let result = try await group.next() {
        guard let result else { continue }
        group.cancelAll()
        return result
      }
      throw ImageBuildError.stepTimeout(step: step)
    }
  }

  // MARK: - Consumption

  private static func consume(
    stream: AsyncThrowingStream<ExecEvent, any Error>, log: BuildLogWriter, step: Int,
    capture: Bool, heartbeat: Heartbeat
  ) async throws -> StepOutcome {
    var buffers: [ExecStream: Data] = [:]
    var captured = Data()
    var tail: [String] = []
    var exitCode: Int32 = -1
    for try await event in stream {
      await heartbeat.touch()
      switch event {
      case let .stdout(data):
        if capture { captured.append(data) }
        try await emit(data, stream: .stdout, buffers: &buffers, tail: &tail, log: log, step: step)
      case let .stderr(data):
        try await emit(data, stream: .stderr, buffers: &buffers, tail: &tail, log: log, step: step)
      case let .exited(code):
        exitCode = code
      }
    }
    for (source, remainder) in buffers where !remainder.isEmpty {
      try await write(
        line: String(decoding: remainder, as: UTF8.self), stream: source, tail: &tail, log: log,
        step: step)
    }
    return StepOutcome(
      exitCode: exitCode, stdout: capture ? String(decoding: captured, as: UTF8.self) : "",
      tail: tail)
  }

  /// Chunks arrive on byte boundaries, not line boundaries, so partial lines are held until their
  /// newline shows up. Interleaving stdout and stderr per line is what makes the transcript read
  /// like a terminal session rather than two shuffled streams.
  private static func emit(
    _ data: Data, stream source: ExecStream, buffers: inout [ExecStream: Data],
    tail: inout [String], log: BuildLogWriter, step: Int
  ) async throws {
    var pending = (buffers[source] ?? Data()) + data
    while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
      let line = pending[pending.startIndex..<index]
      pending = pending[pending.index(after: index)...]
      try await write(
        line: String(decoding: line, as: UTF8.self), stream: source, tail: &tail, log: log,
        step: step)
    }
    buffers[source] = Data(pending)
  }

  private static func write(
    line: String, stream source: ExecStream, tail: inout [String], log: BuildLogWriter, step: Int
  ) async throws {
    let text = "[\(source.rawValue)] \(line)"
    tail.append(text)
    if tail.count > tailLines { tail.removeFirst(tail.count - tailLines) }
    guard await log.line(text) else { throw ImageBuildError.stepOutputTooLarge(step: step) }
  }

  // MARK: - Ceilings

  private static func watch(
    heartbeat: Heartbeat, step: Int, idleTimeout: Duration, deadline: ContinuousClock.Instant,
    pollInterval: Duration
  ) async throws {
    while true {
      try await Task.sleep(for: pollInterval)
      if ContinuousClock.now >= deadline { throw ImageBuildError.timeout }
      if await heartbeat.elapsed() >= idleTimeout {
        throw ImageBuildError.stepTimeout(step: step)
      }
    }
  }

  /// When the guest last said anything at all. Shared between the consuming task and the watchdog,
  /// so it has to be an actor rather than a captured `var`.
  private actor Heartbeat {
    private var last = ContinuousClock.now

    func touch() { last = ContinuousClock.now }

    func elapsed() -> Duration { ContinuousClock.now - last }
  }
}
