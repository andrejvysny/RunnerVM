import Foundation
import RunnerCore

/// What one external tool invocation produced. `stdout`/`stderr` are captured whole: every caller
/// here runs a bounded helper (`tar`, `hdiutil`), never something that streams a disk image.
public struct ProcessResult: Sendable, Hashable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String

  public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// The seam the image builder shells out through. Production is `SystemProcessRunner`; tests inject
/// a stub so no test ever depends on `hdiutil` being usable in the session it happens to run in.
public protocol ProcessRunner: Sendable {
  func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ProcessResult

  /// Same, but with each line handed to `onOutput` as it arrives.
  ///
  /// A defaulted requirement rather than a plain extension method: the default below simply runs
  /// the buffered form and replays its output, which is all a fake in a test needs, while
  /// `SystemProcessRunner` overrides it so a 40-minute macOS provisioning run is followable in
  /// `build.log` instead of appearing all at once when it ends.
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult
}

public extension ProcessRunner {
  func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult {
    let result = try await run(executable, arguments, timeout: timeout)
    for line in (result.stdout + result.stderr).split(separator: "\n", omittingEmptySubsequences: true) {
      onOutput(String(line))
    }
    return result
  }
}

extension ProcessRunner {
  /// Runs `executable` and turns a non-zero exit into `BUILD_TOOL_FAILED`-shaped diagnostics. The
  /// tail of stderr travels with the error: an `hdiutil` failure is otherwise a bare exit code.
  func runChecked(
    _ executable: String, _ arguments: [String], timeout: Duration = .seconds(600)
  ) async throws {
    let result = try await run(executable, arguments, timeout: timeout)
    guard result.exitCode == 0 else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw ImageBuildError.sealFailed(
        reason: "\(executable) exited \(result.exitCode): \(String(detail.suffix(400)))")
    }
  }
}

/// Minimal `Process` wrapper: absolute argv[0], captured pipes, a wall-clock ceiling.
///
/// `Process` has no timeout of its own, so a hung helper would hang the build's whole stage ladder
/// past the point where cancellation could still tear the VM down cleanly.
public struct SystemProcessRunner: ProcessRunner {
  public init() {}

  public func run(
    _ executable: String, _ arguments: [String], timeout: Duration
  ) async throws -> ProcessResult {
    try await run(executable, arguments, timeout: timeout, onOutput: { _ in })
  }

  public func run(
    _ executable: String, _ arguments: [String], timeout: Duration,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> ProcessResult {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw ImageBuildError.toolMissing(tool: executable)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()

    let watchdog = Task {
      try await Task.sleep(for: timeout)
      if process.isRunning { process.terminate() }
    }
    defer { watchdog.cancel() }
    // Both pipes are drained *concurrently*, and to EOF before the exit is collected: a helper
    // that fills either 64 KiB pipe buffer would otherwise block forever on write while this side
    // blocks on exit or on the other pipe. The macOS provisioning script logs steadily to stderr
    // for the length of a run, so draining stdout first and stderr afterwards would deadlock.
    //
    // All three blocking steps run on Dispatch rather than in this task: `read(2)` and
    // `waitUntilExit` would each park a cooperative-pool thread for as long as the helper runs.
    let collected = OutputBox()
    return await withCheckedContinuation { continuation in
      let group = DispatchGroup()
      let queue = DispatchQueue.global(qos: .utility)
      queue.async(group: group) { collected.set(stdout: Self.drain(out, onOutput: onOutput)) }
      queue.async(group: group) { collected.set(stderr: Self.drain(err, onOutput: onOutput)) }
      group.notify(queue: queue) {
        process.waitUntilExit()
        continuation.resume(
          returning: ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: collected.stdout, as: UTF8.self),
            stderr: String(decoding: collected.stderr, as: UTF8.self)))
      }
    }
  }

  /// Reads a pipe to EOF, publishing whole lines as they arrive and returning everything read.
  /// Line-buffered on purpose: a partial line handed to `build.log` would interleave with the
  /// other pipe's output mid-word.
  private static func drain(_ pipe: Pipe, onOutput: @Sendable (String) -> Void) -> Data {
    var buffered = Data()
    var pending = Data()
    while true {
      let chunk = pipe.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      buffered.append(chunk)
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 0x0A) {
        onOutput(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
        pending = pending[pending.index(after: newline)...]
      }
    }
    if !pending.isEmpty { onOutput(String(decoding: pending, as: UTF8.self)) }
    return buffered
  }

  /// Carries the two readers' results back across the `DispatchGroup`. A tiny lock rather than an
  /// actor: the writers are `DispatchQueue` blocks, which cannot `await`.
  private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(stdout data: Data) { lock.withLock { out = data } }
    func set(stderr data: Data) { lock.withLock { err = data } }
    var stdout: Data { lock.withLock { out } }
    var stderr: Data { lock.withLock { err } }
  }
}
