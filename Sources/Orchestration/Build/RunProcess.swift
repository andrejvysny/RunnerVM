import Foundation
import ProcessSpawn
import RunnerCore

/// What one external tool invocation produced. `stdout`/`stderr` are the retained text, capped at
/// both ends by the runner: a caller that needs every byte streams it through `onOutput`.
public struct ProcessResult: Sendable, Hashable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  /// The wall-clock ceiling expired and the tool's process group was killed. `exitCode` alone
  /// cannot say so -- a tool that handles `SIGTERM` and exits cleanly still exits `0`.
  public var timedOut: Bool
  /// The build task was cancelled and the tool's process group was killed for that reason.
  /// Checked before everything else: a cancelled build is cancelled, not a tool failure.
  public var cancelled: Bool

  public init(
    exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
    cancelled: Bool = false
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.cancelled = cancelled
  }
}

/// The seam the image builder shells out through. Production is `SystemProcessRunner`; tests inject
/// a stub so no test ever depends on `hdiutil` being usable in the session it happens to run in.
public protocol ProcessRunner: Sendable {
  /// `environment` is handed to the child verbatim; `nil` means the allowlist
  /// `SpawnRequest.defaultEnvironment()` builds. Nothing is ever inherited wholesale -- runnerd's
  /// own environment carries GitHub and registry credentials.
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]?
  ) async throws -> ProcessResult

  /// Same, but with the leader's pid handed to `onSpawn` the moment it exists and each line
  /// handed to `onOutput` as it arrives.
  ///
  /// A defaulted requirement rather than a plain extension method: the default below simply runs
  /// the buffered form and replays its output, which is all a fake in a test needs, while
  /// `SystemProcessRunner` overrides it so a 40-minute macOS provisioning run is followable in
  /// `build.log` instead of appearing all at once when it ends.
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]?, onSpawn: (@Sendable (pid_t) -> Void)?,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult
}

public extension ProcessRunner {
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]?, onSpawn _: (@Sendable (pid_t) -> Void)?,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult {
    let result = try await run(executable, arguments, timeout: timeout, environment: environment)
    for line in (result.stdout + result.stderr).split(separator: "\n", omittingEmptySubsequences: true) {
      onOutput(String(line))
    }
    return result
  }

  /// The shorthands almost every call site uses: the default environment, no pid hook, and no
  /// streaming.
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration
  ) async throws -> ProcessResult {
    try await run(executable, arguments, timeout: timeout, environment: nil)
  }

  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]? = nil, onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult {
    try await run(
      executable, arguments, timeout: timeout, environment: environment, onSpawn: nil,
      onOutput: onOutput)
  }
}

extension ProcessRunner {
  /// Runs `executable` and turns a non-zero exit into `BUILD_TOOL_FAILED`-shaped diagnostics. The
  /// tail of stderr travels with the error: an `hdiutil` failure is otherwise a bare exit code.
  func runChecked(
    _ executable: String, _ arguments: [String], timeout: Duration = .seconds(600)
  ) async throws {
    let result = try await run(executable, arguments, timeout: timeout)
    // Cancellation first: `ImageBuilderStages` turns a thrown error into `BUILD_CANCELLED` only
    // when it is a `CancellationError`, so reporting a cancelled build as a tool timeout would
    // record a deliberate `build cancel` as a failure.
    guard !result.cancelled else { throw CancellationError() }
    // Then the ceiling: a killed tool's exit code says which signal ended it, not what went
    // wrong, and "it ran out of time" is the only actionable thing to report.
    guard !result.timedOut else {
      throw ImageBuildError.toolTimedOut(
        tool: executable, seconds: Int(timeout.components.seconds))
    }
    guard result.exitCode == 0 else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw ImageBuildError.sealFailed(
        reason: "\(executable) exited \(result.exitCode): \(String(detail.suffix(400)))")
    }
  }
}

/// `ProcessSpawn` behind the builder's seam: an explicit environment, a process group that
/// escalation can reach, a drain that ends whether or not the pipes do, and a decoded exit code.
///
/// `Foundation.Process` used to be here and could not provide any of them -- see `ProcessSpawn`
/// for what each one is worth. `killGrace`/`drainGrace` are injectable so a test can exercise the
/// whole ladder in milliseconds.
public struct SystemProcessRunner: ProcessRunner {
  private let killGrace: Duration
  private let drainGrace: Duration

  public init(killGrace: Duration = .seconds(10), drainGrace: Duration = .seconds(5)) {
    self.killGrace = killGrace
    self.drainGrace = drainGrace
  }

  public func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]?
  ) async throws -> ProcessResult {
    try await run(
      executable, arguments, timeout: timeout, environment: environment, onSpawn: nil,
      onOutput: { _ in })
  }

  public func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    environment: [String: String]?, onSpawn: (@Sendable (pid_t) -> Void)?,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult {
    let request = SpawnRequest(
      executable: executable, arguments: arguments, environment: environment, timeout: timeout,
      killGrace: killGrace, drainGrace: drainGrace)
    do {
      let result = try await ProcessSpawn.run(request, onSpawn: onSpawn, onOutput: onOutput)
      return ProcessResult(
        exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
        timedOut: result.timedOut, cancelled: result.cancelled)
    } catch SpawnError.executableMissing {
      throw ImageBuildError.toolMissing(tool: executable)
    }
  }
}
