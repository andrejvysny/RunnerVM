import Darwin
import Foundation
import Logging
import ProcessSpawn
import RunnerCore
import Testing

@testable import Orchestration

/// The builder's process seam against real children. `killGrace`/`drainGrace` are millisecond-scale
/// so the whole escalation ladder runs inside a test, and every case is under a hang guard: the
/// bug class this replaced `Foundation.Process` for is "never returns".
@Suite struct RunProcessTests {
  private static let shell = "/bin/sh"

  private var runner: SystemProcessRunner {
    SystemProcessRunner(killGrace: .milliseconds(200), drainGrace: .milliseconds(200))
  }

  @Test func aBoundedToolIsRunAndCaptured() async throws {
    let result = try await withHangGuard("/bin/echo") {
      try await SystemProcessRunner().run("/bin/echo", ["hi"], timeout: .seconds(10))
    }
    #expect(result.exitCode == 0)
    #expect(result.stdout == "hi\n")
    #expect(!result.timedOut)
  }

  @Test func aToolThatIgnoresSIGTERMIsKilledAndReportedAsTimedOut() async throws {
    let started = ContinuousClock.now
    let result = try await withHangGuard("the escalation ladder", limit: .seconds(60)) { [runner] in
      try await runner.run(
        Self.shell, ["-c", "echo working; trap '' TERM; sleep 60"], timeout: .milliseconds(300))
    }
    #expect(result.timedOut)
    #expect(result.exitCode == 128 + SIGKILL)
    // Output written before the kill still travels back: it is usually the only clue.
    #expect(result.stdout.contains("working"))
    // Far below the child's own 60 s: the bound proves the ladder ran, not how fast.
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  /// `expect` puts what it spawns in its own session, so a group kill never reaches the
  /// grandchild and a read-to-EOF drain would wait for it.
  @Test func aSetsidGrandchildCannotStretchTheCall() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/expect"))
    let started = ContinuousClock.now
    let result = try await withHangGuard(
      "the expect grandchild to stop mattering", limit: .seconds(60)
    ) { [runner] in
      try await runner.run(
        "/usr/bin/expect", ["-c", "spawn -noecho sleep 60; expect eof"], timeout: .milliseconds(300))
    }
    #expect(result.timedOut)
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test func aTimedOutToolIsReportedAsBUILDTOOLTIMEOUTRatherThanAFailedSeal() async throws {
    do {
      try await runner.runChecked(
        Self.shell, ["-c", "trap '' TERM; sleep 60"], timeout: .milliseconds(300))
      Issue.record("a timed-out tool must not look like success")
    } catch let error as ImageBuildError {
      #expect(error.code == "BUILD_TOOL_TIMEOUT")
      #expect(!error.retryable)
    }
  }

  /// `ImageBuilderStages` turns a thrown `CancellationError` into `BUILD_CANCELLED`; anything
  /// else it sees becomes a failure. So a cancelled build reported as `BUILD_TOOL_TIMEOUT` would
  /// record an operator's `build cancel` as the host's fault.
  @Test func aCancelledToolIsCancelledNotTimedOut() async throws {
    let started = ContinuousClock.now
    let outcome = Task { () -> (any Error)? in
      do {
        try await SystemProcessRunner(killGrace: .milliseconds(300), drainGrace: .milliseconds(200))
          .runChecked(Self.shell, ["-c", "trap '' TERM; sleep 300"], timeout: .seconds(300))
        return nil
      } catch {
        return error
      }
    }
    // Cancelling before the spawn is a legal state too: `SpawnControl` replays the flag the moment
    // there is a process group to aim at.
    outcome.cancel()

    let error = try await withHangGuard("the cancelled tool", limit: .seconds(60)) {
      await outcome.value
    }
    #expect(error is CancellationError)
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test func aMissingToolIsBUILDTOOLMISSING() async throws {
    do {
      _ = try await SystemProcessRunner().run(
        "/tmp/rvm-not-a-tool-\(UUID().uuidString)", [], timeout: .seconds(1))
      Issue.record("a missing tool must not run")
    } catch let error as ImageBuildError {
      #expect(error.code == "BUILD_TOOL_MISSING")
    }
  }

  @Test func everyLineIsStreamedAsItArrives() async throws {
    let seen = LineBox()
    let result = try await withHangGuard("streamed output") {
      try await SystemProcessRunner().run(
        Self.shell, ["-c", "echo one; echo two >&2; echo three"], timeout: .seconds(10),
        onOutput: { seen.append($0) })
    }
    #expect(result.exitCode == 0)
    #expect(Set(seen.lines) == ["one", "two", "three"])
  }

  /// `posix_spawn` inherits nothing, so what a tool sees is exactly what the call named.
  @Test func onlyTheSuppliedEnvironmentReachesTheTool() async throws {
    setenv("RVM_RUNPROCESS_LEAK_CHECK", "leaked", 1)
    defer { unsetenv("RVM_RUNPROCESS_LEAK_CHECK") }
    let result = try await withHangGuard("/usr/bin/env") {
      try await SystemProcessRunner().run(
        "/usr/bin/env", [], timeout: .seconds(10),
        environment: ["PATH": "/usr/bin:/bin", "RVM_RUNPROCESS_MARKER": "kept"])
    }
    #expect(result.stdout.contains("RVM_RUNPROCESS_MARKER=kept"))
    #expect(!result.stdout.contains("RVM_RUNPROCESS_LEAK_CHECK"))
  }
}

/// The marker that lets a restarted daemon find a provisioning script its predecessor spawned.
@Suite struct ProvisionProcessGroupTests {
  @Test func terminateReachesTheWholeRecordedGroupAndClearsTheMarker() async throws {
    let work = try TempTree()
    defer { work.remove() }
    let (lines, publish) = AsyncStream<String>.makeStream()
    let root = work.root
    // `publish.finish()` in a `defer` on the spawning task, never after the wait below: a child
    // that produces no output at all must end the stream rather than leave `next()` -- and the
    // whole suite -- waiting for a line that is never coming.
    let task = Task {
      defer { publish.finish() }
      return try await ProcessSpawn.run(
        SpawnRequest(
          executable: "/bin/sh",
          arguments: ["-c", "trap 'exit 7' TERM; echo up; sleep 60"],
          timeout: .seconds(30), killGrace: .seconds(5), drainGrace: .milliseconds(200)),
        onSpawn: { ProvisionProcessGroup.record($0, in: root) },
        onOutput: { publish.yield($0) })
    }
    var iterator = lines.makeAsyncIterator()
    _ = await iterator.next()

    let signalled = ProvisionProcessGroup.terminate(in: root, logger: Logger(label: "test"))
    #expect(signalled != nil)
    #expect(!FileManager.default.fileExists(
      atPath: ProvisionProcessGroup.marker(in: root).path(percentEncoded: false)))

    let result = try await withHangGuard("the terminated script", limit: .seconds(60)) {
      try await task.value
    }
    // The script's own `TERM` trap ran, which is the whole reason the ladder starts with SIGTERM.
    #expect(result.exitCode == 7)
    #expect(signalled == result.pgid)
  }

  /// A pid is not an identity: after a restart the kernel may have handed it to something else.
  @Test func aMarkerWhosePidIsGoneSignalsNothing() async throws {
    let work = try TempTree()
    defer { work.remove() }
    let done = try await ProcessSpawn.run(
      SpawnRequest(executable: "/usr/bin/true", timeout: .seconds(10)))
    #expect(ProcessSpawn.startTime(of: done.pid) == nil)
    try Data("\(done.pid) 1234567890\n".utf8).write(
      to: ProvisionProcessGroup.marker(in: work.root))

    #expect(ProvisionProcessGroup.terminate(in: work.root, logger: Logger(label: "test")) == nil)
    // Stale either way: a marker that no longer matches a live process is removed, not retried.
    #expect(!FileManager.default.fileExists(
      atPath: ProvisionProcessGroup.marker(in: work.root).path(percentEncoded: false)))
  }

  @Test func aMarkerWhoseStartTimeDisagreesSignalsNothing() async throws {
    let work = try TempTree()
    defer { work.remove() }
    let (lines, publish) = AsyncStream<String>.makeStream()
    let root = work.root
    let spawned = PidBox()
    let task = Task {
      defer { publish.finish() }
      return try await ProcessSpawn.run(
        SpawnRequest(
          executable: "/bin/sh", arguments: ["-c", "echo up; sleep 60"],
          timeout: .seconds(30), killGrace: .milliseconds(200), drainGrace: .milliseconds(200)),
        onSpawn: { pid in
          // The recorded pid is live, but its start time is not the one on the marker: exactly the
          // shape of a recycled pid, and the one case a naive `kill(-pgid)` would get wrong.
          spawned.value = pid
          let started = ProcessSpawn.startTime(of: pid) ?? 0
          try? Data("\(pid) \(started + 1)\n".utf8).write(
            to: ProvisionProcessGroup.marker(in: root))
        },
        onOutput: { publish.yield($0) })
    }
    var iterator = lines.makeAsyncIterator()
    _ = await iterator.next()

    #expect(ProvisionProcessGroup.terminate(in: root, logger: Logger(label: "test")) == nil)
    // Still the live process it was: the mismatch stopped the signal before `kill` was reached.
    #expect(ProcessSpawn.startTime(of: spawned.value) != nil)

    task.cancel()
    let result = try await withHangGuard("the untouched script", limit: .seconds(60)) {
      try await task.value
    }
    #expect(!result.timedOut)
  }

  /// The other half of the seam the provisioning stage drives: what `onSpawn` writes, the stage
  /// takes away again when the script is done.
  @Test func recordThenClearLeavesNoMarker() throws {
    let work = try TempTree()
    defer { work.remove() }
    ProvisionProcessGroup.record(getpid(), in: work.root)
    #expect(FileManager.default.fileExists(
      atPath: ProvisionProcessGroup.marker(in: work.root).path(percentEncoded: false)))

    ProvisionProcessGroup.clear(in: work.root)

    #expect(!FileManager.default.fileExists(
      atPath: ProvisionProcessGroup.marker(in: work.root).path(percentEncoded: false)))
  }

  /// This daemon's own group is never a target, whatever a marker claims.
  @Test func aMarkerNamingThisProcessIsNeverSignalled() throws {
    let work = try TempTree()
    defer { work.remove() }
    ProvisionProcessGroup.record(getpid(), in: work.root)

    #expect(ProvisionProcessGroup.terminate(in: work.root, logger: Logger(label: "test")) == nil)
    #expect(!FileManager.default.fileExists(
      atPath: ProvisionProcessGroup.marker(in: work.root).path(percentEncoded: false)))
  }

  @Test func noMarkerIsNotAnError() throws {
    let work = try TempTree()
    defer { work.remove() }
    #expect(ProvisionProcessGroup.terminate(in: work.root, logger: Logger(label: "test")) == nil)
  }
}

/// The spawned leader's pid, written from the spawn hook and read by the test.
private final class PidBox: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: pid_t = 0

  var value: pid_t {
    get { lock.withLock { pid } }
    set { lock.withLock { pid = newValue } }
  }
}

/// Collects streamed lines. They all arrive on the one drain thread, so a plain lock is enough.
private final class LineBox: @unchecked Sendable {
  private let lock = NSLock()
  private var collected: [String] = []

  func append(_ line: String) { lock.withLock { collected.append(line) } }
  var lines: [String] { lock.withLock { collected } }
}
