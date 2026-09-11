import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// `DefaultCommandRunner` against real commands. `setup` runs `launchctl`/`dscl`/`installer` as
/// root, so the properties that matter are the ones a wedged one of those used to break: a
/// ceiling, both pipes drained at once, and a decoded exit code.
@Suite struct CommandRunnerTests {
  private static let shell = "/bin/sh"

  /// Fails the test instead of hanging the suite.
  private func guarded<T: Sendable>(
    _ description: String, _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(for: .seconds(60))
        throw TestError("timed out waiting for \(description)")
      }
      guard let first = try await group.next() else { throw TestError("no result") }
      group.cancelAll()
      return first
    }
  }

  private var runner: DefaultCommandRunner {
    DefaultCommandRunner(killGrace: .milliseconds(200), drainGrace: .milliseconds(200))
  }

  @Test func aCommandIsRunAndItsOutputCaptured() async throws {
    let result = try await guarded("/bin/echo") {
      try await DefaultCommandRunner().run(["/bin/echo", "hello"])
    }
    #expect(result.isSuccess)
    #expect(result.trimmedStdout == "hello")
    #expect(!result.timedOut)
  }

  @Test func stdinIsWrittenAndClosed() async throws {
    let result = try await guarded("/usr/bin/wc") {
      try await DefaultCommandRunner().run(["/bin/cat"], stdin: "a\nb\n")
    }
    #expect(result.stdout == "a\nb\n")
  }

  @Test func aNonZeroExitCarriesStderrAsTheFailureDetail() async throws {
    let result = try await guarded("a failing command") {
      try await DefaultCommandRunner().run([Self.shell, "-c", "echo nope >&2; exit 3"])
    }
    #expect(result.exitCode == 3)
    #expect(result.failureDetail == "nope")
  }

  /// Reading stdout to EOF before touching stderr deadlocks against a command whose diagnostics
  /// fill the 64 KiB stderr buffer first -- `dscl` and `installer` both write plenty of both.
  @Test func aCommandThatFillsStderrFirstStillCompletes() async throws {
    let script = "i=0; while [ $i -lt 512 ]; do printf '%0256d\\n' \"$i\" >&2; i=$((i + 1)); done; echo done"
    let result = try await guarded("both pipes") {
      try await DefaultCommandRunner().run([Self.shell, "-c", script])
    }
    #expect(result.isSuccess)
    #expect(result.trimmedStdout == "done")
    #expect(result.stderr.count > 128 * 1_024)
  }

  @Test func aWedgedCommandIsKilledAtItsCeiling() async throws {
    let started = ContinuousClock.now
    let result = try await guarded("the escalation ladder") { [runner] in
      try await runner.run(
        [Self.shell, "-c", "trap '' TERM; sleep 60"], stdin: nil, timeout: .milliseconds(300))
    }
    #expect(result.timedOut)
    #expect(!result.isSuccess)
    // Far below the child's own 60 s: the bound proves the ladder ran, not how fast.
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test func runCheckedSaysTheCommandTimedOutRatherThanNamingASignal() async throws {
    do {
      try await guarded("runChecked") { [runner] in
        try await runner.runChecked(
          [Self.shell, "-c", "trap '' TERM; sleep 60"], timeout: .milliseconds(300))
      }
      Issue.record("a killed command must not look like success")
    } catch let error as SetupError {
      #expect(error.code == "SETUP_COMMAND_FAILED")
      #expect(error.message.contains("timed out after"))
      #expect(error.message.contains("was killed"))
    }
  }

  @Test func aMissingExecutableIsReportedAsSuch() async throws {
    await #expect(throws: SetupError.self) {
      _ = try await DefaultCommandRunner().run(["/tmp/rvm-not-a-tool-\(UUID().uuidString)"])
    }
    await #expect(throws: SetupError.self) {
      _ = try await DefaultCommandRunner().run([])
    }
  }

  /// Every host tool this module runs answers in well under a minute or is stuck; the exceptions
  /// (a release download, `installer`) name their own ceiling.
  @Test func theDefaultCeilingIsOneMinute() {
    #expect(DefaultCommandRunner.defaultTimeout == .seconds(60))
    #expect(DefaultCommandRunner.describe(nil) == "\(Duration.seconds(60))")
    #expect(DefaultCommandRunner.describe(.seconds(900)) == "\(Duration.seconds(900))")
  }
}
