import Darwin
import Foundation
import Testing

@testable import ProcessSpawn

/// Every case drives a real child, with `killGrace`/`drainGrace` at millisecond scale so a ladder
/// that would take fifteen seconds in production takes a few hundred milliseconds here.
@Suite struct ProcessSpawnTests {
  private static let shell = "/bin/sh"

  private func request(
    _ executable: String, _ arguments: [String] = [], timeout: Duration = .seconds(20),
    killGrace: Duration = .milliseconds(200), drainGrace: Duration = .milliseconds(200),
    environment: [String: String]? = nil, standardInput: String? = nil,
    captureLimit: Int = 256 << 10
  ) -> SpawnRequest {
    SpawnRequest(
      executable: executable, arguments: arguments, environment: environment,
      standardInput: standardInput, timeout: timeout, killGrace: killGrace,
      drainGrace: drainGrace, captureLimit: captureLimit)
  }

  @Test func aSimpleCommandIsCapturedAndItsProcessGroupIsItsOwn() async throws {
    let result = try await withHangGuard("/bin/echo") {
      try await ProcessSpawn.run(
        SpawnRequest(executable: "/bin/echo", arguments: ["hi"], timeout: .seconds(10)))
    }
    #expect(result.exitCode == 0)
    #expect(result.stdout == "hi\n")
    #expect(result.stderr.isEmpty)
    #expect(!result.timedOut)
    // `POSIX_SPAWN_SETPGROUP` with pgroup 0: the leader's pid *is* its process group id, which is
    // what makes `kill(-pgid, …)` reach everything it forks.
    #expect(result.pgid == result.pid)
    #expect(result.pid > 0)
    #expect(isReaped(result.pid))
  }

  @Test func aMissingExecutableIsRejectedBeforeAnythingIsSpawned() async throws {
    await #expect(throws: SpawnError.self) {
      _ = try await ProcessSpawn.run(
        SpawnRequest(executable: "/tmp/rvm-not-a-binary-\(UUID().uuidString)", timeout: .seconds(1)))
    }
  }

  @Test func aChildThatIgnoresSIGTERMIsKilledAtTheGrace() async throws {
    let started = ContinuousClock.now
    let result = try await withHangGuard("the escalation ladder") {
      try await ProcessSpawn.run(
        self.request(Self.shell, ["-c", "trap '' TERM; sleep 60"], timeout: .milliseconds(300)))
    }
    #expect(result.timedOut)
    #expect(result.exitCode == 128 + SIGKILL)
    // Far below the child's own 60 s: the bound proves the ladder ran, not how fast. A loaded
    // host can schedule the drain and the watchdog seconds late.
    #expect(ContinuousClock.now - started < .seconds(20))
    #expect(isReaped(result.pid))
  }

  /// The regression this whole target exists for: runnerd `SIG_IGN`s `SIGTERM`, an ignored
  /// disposition survives `exec`, and a child that inherits it cannot install its own trap
  /// ("signals ignored on entry to the shell cannot be trapped"). Without
  /// `POSIX_SPAWN_SETSIGDEF` this child would ignore the `SIGTERM` leg entirely and die of the
  /// `SIGKILL` that follows, skipping the `trap cleanup EXIT` a provisioning script relies on.
  @Test func anIgnoredSIGTERMDispositionIsNotInheritedByTheChild() async throws {
    let previous = signal(SIGTERM, SIG_IGN)
    defer { signal(SIGTERM, previous) }
    let result = try await withHangGuard("the child's own SIGTERM trap") {
      try await ProcessSpawn.run(
        self.request(
          Self.shell, ["-c", "trap 'exit 42' TERM; sleep 60"], timeout: .milliseconds(300),
          killGrace: .seconds(5)))
    }
    #expect(result.timedOut)
    #expect(result.exitCode == 42)
  }

  /// `expect` puts what it spawns in its own session, so the group kill does not reach the
  /// grandchild. The call still has to end.
  @Test func aGrandchildInItsOwnSessionCannotStretchTheCall() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/expect"))
    let started = ContinuousClock.now
    let result = try await withHangGuard("the setsid grandchild to stop mattering") {
      try await ProcessSpawn.run(
        self.request(
          "/usr/bin/expect", ["-c", "spawn -noecho sleep 60; expect eof"],
          timeout: .milliseconds(300)))
    }
    #expect(result.timedOut)
    #expect(ContinuousClock.now - started < .seconds(20))
    #expect(isReaped(result.pid))
  }

  /// A process that daemonised itself keeps the pipe's write end open after the leader is gone, so
  /// reading to EOF would never return. The drain stops `drainGrace` after the leader exits.
  @Test func aDetachedPipeHolderDoesNotHoldTheDrainOpen() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
    // The detached holder outlives anything this test is willing to wait for, so a drain that
    // waited for EOF instead of the grace could not pass.
    let script = "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); sleep 120' & echo leader; exec sleep 0.2"
    let started = ContinuousClock.now
    let result = try await withHangGuard("the drain grace to expire") {
      try await ProcessSpawn.run(
        self.request(Self.shell, ["-c", script], timeout: .seconds(20), drainGrace: .milliseconds(300)))
    }
    #expect(!result.timedOut)
    #expect(result.stdout.contains("leader"))
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test func outputWrittenBeforeTheDeadlineSurvivesTheKill() async throws {
    let result = try await withHangGuard("a timed-out run to keep its output") {
      try await ProcessSpawn.run(
        self.request(
          Self.shell, ["-c", "echo before-the-wait; echo also-stderr >&2; trap '' TERM; sleep 60"],
          timeout: .milliseconds(300)))
    }
    #expect(result.timedOut)
    #expect(result.stdout.contains("before-the-wait"))
    #expect(result.stderr.contains("also-stderr"))
  }

  @Test func cancellingTheCallerSignalsAndStillReapsTheLeader() async throws {
    let (lines, publish) = AsyncStream<String>.makeStream()
    // `publish.finish()` in a `defer` on the spawning task, never after the wait below: a child
    // that produces no output at all must end the stream rather than leave `next()` -- and the
    // whole suite -- waiting for a line that is never coming.
    let task = Task {
      defer { publish.finish() }
      return try await ProcessSpawn.run(
        self.request(Self.shell, ["-c", "echo up; sleep 60"], timeout: .seconds(30)),
        onOutput: { publish.yield($0) })
    }
    var iterator = lines.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    let result = try await withHangGuard("the cancelled child to be reaped") { try await task.value }
    #expect(result.exitCode != 0)
    #expect(!result.timedOut)
    #expect(isReaped(result.pid))
  }

  /// Cancellation gets the same second rung the timeout ladder has. Without it a `build cancel`
  /// on a script that traps `SIGTERM` would wait out the build's own timeout -- forty minutes --
  /// before the row could be released.
  @Test func cancellingAChildThatIgnoresSIGTERMStillEndsAtTheKillGrace() async throws {
    let (lines, publish) = AsyncStream<String>.makeStream()
    let task = Task {
      defer { publish.finish() }
      return try await ProcessSpawn.run(
        self.request(
          Self.shell, ["-c", "trap '' TERM; echo up; sleep 300"], timeout: .seconds(300),
          killGrace: .milliseconds(300)),
        onOutput: { publish.yield($0) })
    }
    var iterator = lines.makeAsyncIterator()
    _ = await iterator.next()
    let cancelled = ContinuousClock.now
    task.cancel()

    let result = try await withHangGuard("the cancel ladder") { try await task.value }
    #expect(result.cancelled)
    // Not a timeout: the 300 s ceiling never came near firing, and a caller that conflated the
    // two would record a deliberate cancel as a tool that ran out of time.
    #expect(!result.timedOut)
    #expect(result.exitCode == 128 + SIGKILL)
    // Bounded by `killGrace`, not by the 300 s the child would otherwise have slept.
    #expect(ContinuousClock.now - cancelled < .seconds(20))
    #expect(isReaped(result.pid))
  }

  /// `Process.terminationStatus` reports a raw wait status on some paths, where "killed by
  /// SIGKILL" is `9` -- indistinguishable from "exited 9".
  @Test func aSignalDeathIsReportedAs128PlusTheSignal() async throws {
    let result = try await withHangGuard("a self-killed child") {
      try await ProcessSpawn.run(self.request(Self.shell, ["-c", "kill -9 $$"]))
    }
    #expect(result.exitCode == 137)
    #expect(!result.timedOut)
  }

  @Test func statusDecodingCoversExitAndSignalDeaths() {
    #expect(ProcessSpawn.exitCode(fromWaitStatus: 0) == 0)
    #expect(ProcessSpawn.exitCode(fromWaitStatus: 1 << 8) == 1)
    #expect(ProcessSpawn.exitCode(fromWaitStatus: 42 << 8) == 42)
    #expect(ProcessSpawn.exitCode(fromWaitStatus: SIGKILL) == 137)
    #expect(ProcessSpawn.exitCode(fromWaitStatus: SIGTERM) == 143)
  }

  /// Draining stdout to EOF before touching stderr deadlocks against this child.
  @Test func aChildThatFillsStderrFirstStillCompletes() async throws {
    let script = "i=0; while [ $i -lt 512 ]; do printf '%0256d\\n' \"$i\" >&2; i=$((i + 1)); done; echo done"
    let result = try await withHangGuard("both pipes to be drained") {
      try await ProcessSpawn.run(self.request(Self.shell, ["-c", script]))
    }
    #expect(result.exitCode == 0)
    #expect(result.stdout == "done\n")
    #expect(result.stderr.count > 128 * 1_024)
    #expect(!result.outputTruncated)
  }

  @Test func retainedOutputIsCappedAtBothEnds() async throws {
    let script = "i=0; while [ $i -lt 2000 ]; do printf 'line-%04d\\n' \"$i\"; i=$((i + 1)); done"
    let seen = SeenLines()
    let result = try await withHangGuard("a capped capture") {
      try await ProcessSpawn.run(
        self.request(Self.shell, ["-c", script], captureLimit: 1_024),
        onOutput: { _ in seen.increment() })
    }
    #expect(result.exitCode == 0)
    #expect(result.outputTruncated)
    #expect(result.stdout.hasPrefix("line-0000\n"))
    #expect(result.stdout.hasSuffix("line-1999\n"))
    #expect(result.stdout.contains("bytes elided"))
    #expect(result.stdout.count < 4 * 1_024)
    // Everything is still streamed: only what travels back in the result is capped.
    #expect(seen.count == 2_000)
  }

  @Test func standardInputIsDeliveredAndClosed() async throws {
    let result = try await withHangGuard("stdin to be consumed") {
      try await ProcessSpawn.run(
        self.request("/bin/cat", standardInput: "hello\nworld\n"))
    }
    #expect(result.exitCode == 0)
    #expect(result.stdout == "hello\nworld\n")
  }

  /// `posix_spawn` inherits nothing, which is the point: runnerd's environment carries GitHub and
  /// registry credentials.
  @Test func onlyTheSuppliedEnvironmentReachesTheChild() async throws {
    setenv("RVM_SPAWN_LEAK_CHECK", "leaked", 1)
    defer { unsetenv("RVM_SPAWN_LEAK_CHECK") }
    let result = try await withHangGuard("the child's environment") {
      try await ProcessSpawn.run(
        self.request(
          "/usr/bin/env", environment: ["PATH": "/usr/bin:/bin", "RVM_SPAWN_MARKER": "kept"]))
    }
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("RVM_SPAWN_MARKER=kept"))
    #expect(!result.stdout.contains("RVM_SPAWN_LEAK_CHECK"))
  }

  @Test func theDefaultEnvironmentIsTheAllowlistOnly() {
    let built = SpawnRequest.defaultEnvironment(
      from: ["PATH": "/bin", "HOME": "/tmp", "RUNNERVM_GITHUB_TOKEN": "secret", "LC_ALL": "C"])
    #expect(built == ["PATH": "/bin", "HOME": "/tmp", "LC_ALL": "C"])
    #expect(SpawnRequest.defaultEnvironment(from: [:])["PATH"] == SpawnRequest.fallbackPath)
  }
}

/// Counts `onOutput` callbacks. They all arrive on the one drain thread, so a plain lock is enough.
private final class SeenLines: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
