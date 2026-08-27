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
    // Read before `waitUntilExit`: a helper that fills the 64 KiB pipe buffer would otherwise
    // block forever on write while we block on exit.
    let stdout = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    return ProcessResult(
      exitCode: process.terminationStatus,
      stdout: String(decoding: stdout, as: UTF8.self),
      stderr: String(decoding: stderr, as: UTF8.self))
  }
}
