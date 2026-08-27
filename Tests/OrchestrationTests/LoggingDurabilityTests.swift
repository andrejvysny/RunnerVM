import Foundation
import GuestControl
import ImageStore
import Persistence
import RPC
import RunnerCore
import RunnerLogging
import Testing

@testable import Orchestration

/// M14: logs that survive the thing that produced them. The event stream, the retention sweep,
/// and the one-shot window in which a guest's `_diag` can still be read.
@Suite struct LoggingDurabilityTests {
  // MARK: - Lifecycle event stream

  private static func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "rvm-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
  }

  private static func lines(_ url: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map {
      try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }

  @Test func eachTransitionBecomesOneWellFormedLine() async throws {
    try await Self.withTemporaryDirectory { root in
      let url = root.appending(path: "events.jsonl")
      let log = try LifecycleEventLog(url: url, hostId: HostID(rawValue: "host-9"))
      await log.record(
        LifecycleEventLog.instanceTransition,
        LifecycleEventLog.Fields(
          instance: InstanceID(rawValue: "vm-1"), profile: RunnerProfileID(rawValue: "p-1"),
          from: "busy", to: "cleaning"))
      await log.record(
        LifecycleEventLog.sessionTransition,
        LifecycleEventLog.Fields(
          instance: InstanceID(rawValue: "vm-1"), session: RunnerSessionID(rawValue: "s-1"),
          githubRunnerID: 42, from: "jobRunning", to: "completed", reason: "JOB_DONE"))
      await log.close()

      let lines = try Self.lines(url)
      #expect(lines.count == 2)
      #expect(lines[0]["event"] as? String == "instance.transition")
      #expect(lines[0]["host_id"] as? String == "host-9")
      #expect(lines[0]["instance_id"] as? String == "vm-1")
      #expect(lines[0]["profile_id"] as? String == "p-1")
      #expect(lines[0]["from"] as? String == "busy")
      #expect(lines[0]["to"] as? String == "cleaning")
      // Absent fields are omitted rather than emitted as null, so a shipper never indexes them.
      #expect(lines[0]["runner_session_id"] == nil)
      #expect(lines[0]["ts"] is String)
      #expect(lines[1]["runner_session_id"] as? String == "s-1")
      #expect(lines[1]["github_runner_id"] as? Int == 42)
      #expect(lines[1]["reason"] as? String == "JOB_DONE")
    }
  }

  /// `reason` is the only free-text field, so it is the only one a secret could ride in on.
  @Test func theReasonFieldIsRedacted() async throws {
    try await Self.withTemporaryDirectory { root in
      let url = root.appending(path: "events.jsonl")
      let log = try LifecycleEventLog(url: url, hostId: HostID(rawValue: "host-9"))
      await log.record(
        LifecycleEventLog.auditEvent,
        LifecycleEventLog.Fields(reason: "Authorization: Bearer ghp_0123456789abcdefghijklmn"))
      await log.close()

      let reason = try #require(try Self.lines(url).first?["reason"] as? String)
      #expect(!reason.contains("ghp_"))
      #expect(reason.contains("REDACTED"))
    }
  }

  @Test func aLiveInstanceTransitionReachesTheStream() async throws {
    try await withHarness { harness in
      // The harness already attaches `LifecycleEventLog` at `paths.eventsLogFile` to every
      // manager (its own waits are driven by it); the sink writes each line synchronously, so the
      // file is complete the moment the instance is idle.
      let url = harness.paths.eventsLogFile
      let (record, agent) = try await harness.idleInstance()

      let events = try Self.lines(url).filter {
        $0["instance_id"] as? String == record.id.rawValue
      }
      #expect(!events.isEmpty)
      #expect(events.allSatisfy { $0["event"] as? String == "instance.transition" })
      #expect(events.contains { $0["to"] as? String == "idle" })
      #expect(events.allSatisfy { $0["host_id"] as? String == harness.hostId.rawValue })
      await agent.stop()
    }
  }

  // MARK: - Retention sweep

  private static func seedLogDir(
    _ paths: RunnerPaths, _ id: InstanceID, age: TimeInterval
  ) throws {
    let directory = paths.instanceLogDir(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: VMInstanceLayout.serialLogName)
    try Data("console\n".utf8).write(to: file)
    let stamp = Date().addingTimeInterval(-age)
    for url in [file, directory] {
      try FileManager.default.setAttributes([.modificationDate: stamp],
                                            ofItemAtPath: url.path(percentEncoded: false))
    }
  }

  @Test func theSweepDropsOnlyExpiredDirectoriesOfInstancesThatAreGone() async throws {
    try await Self.withTemporaryDirectory { root in
      let paths = RunnerPaths(
        rootDir: root.appending(path: "state", directoryHint: .isDirectory),
        runtimeDir: root.appending(path: "sock", directoryHint: .isDirectory))
      let expired = InstanceID(rawValue: "expired")
      let recent = InstanceID(rawValue: "recent")
      let live = InstanceID(rawValue: "live")
      try Self.seedLogDir(paths, expired, age: 8 * 86_400)
      try Self.seedLogDir(paths, recent, age: 3_600)
      // Old enough to expire, but its instance is still in the database: a long job legitimately
      // writes nothing for hours, so mtime alone must never be enough.
      try Self.seedLogDir(paths, live, age: 8 * 86_400)

      let swept = InstanceLogRetention(paths: paths)
        .sweep(olderThan: .seconds(7 * 86_400), keeping: [live])

      #expect(swept == [expired])
      let manager = FileManager.default
      #expect(!manager.fileExists(atPath: paths.instanceLogDir(expired).path(percentEncoded: false)))
      #expect(manager.fileExists(atPath: paths.instanceLogDir(recent).path(percentEncoded: false)))
      #expect(manager.fileExists(atPath: paths.instanceLogDir(live).path(percentEncoded: false)))
    }
  }

  @Test func aZeroRetentionKeepsEverything() async throws {
    try await Self.withTemporaryDirectory { root in
      let paths = RunnerPaths(
        rootDir: root.appending(path: "state", directoryHint: .isDirectory),
        runtimeDir: root.appending(path: "sock", directoryHint: .isDirectory))
      let id = InstanceID(rawValue: "ancient")
      try Self.seedLogDir(paths, id, age: 400 * 86_400)

      #expect(InstanceLogRetention(paths: paths).sweep(olderThan: .zero, keeping: []).isEmpty)
      #expect(FileManager.default.fileExists(
        atPath: paths.instanceLogDir(id).path(percentEncoded: false)))
    }
  }

  // MARK: - Guest diagnostics

  /// The fake agent answers `agent.exec` with a known payload; the real code path decodes the
  /// base64 chunks and writes the bytes verbatim.
  @Test func theGuestTarballLandsInTheInstanceLogDirectory() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.exec = [.stdout("PRETEND-GZIP-BYTES"), .exit(0)]
      script.runnerStatusSequence = [.online, .busy, .exited].map {
        RunnerStatus(state: $0, pid: 4_242)
      }
      let (instance, agent) = try await harness.idleInstance(script: script)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(session.id).state == .completed)
      try await waitUntil("the ephemeral instance to be deleted") {
        try await harness.record(instance.id).state == .deleted
      }

      let archive = harness.paths.instanceDiagnosticsDir(instance.id)
        .appending(path: InstanceManager.diagnosticsArchiveName)
      #expect(try String(contentsOf: archive, encoding: .utf8) == "PRETEND-GZIP-BYTES")
      // The collection ran while the guest was still up: one exec, before the stop.
      #expect(await agent.callCount(.exec) == 1)
      let argv = try #require(await agent.lastExec()?.argv)
      #expect(argv.first == "/bin/sh")
      #expect(argv.last?.contains("actions-runner") == true)
      #expect(argv.last?.contains("runnervm-guest-agent") == true)
      await agent.stop()
    }
  }

  @Test func theHostSideLogsAreMovedOutOfTheInstanceDirectoryBeforeItIsDeleted() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      let (instance, agent) = try await harness.idleInstance(
        script: {
          var script = FakeGuestAgent.Script()
          script.runnerStatusSequence = [.online, .busy, .exited].map {
            RunnerStatus(state: $0, pid: 4_242)
          }
          return script
        }())
      // The fake worker never writes a serial console, so plant one the way vmworker would.
      let serial = harness.paths.instanceDir(instance.id)
        .appending(path: VMInstanceLayout.serialLogName)
      try Data("boot log\n".utf8).write(to: serial)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)
      try await waitUntil("the ephemeral instance to be deleted") {
        try await harness.record(instance.id).state == .deleted
      }

      let manager = FileManager.default
      #expect(!manager.fileExists(
        atPath: harness.paths.instanceDir(instance.id).path(percentEncoded: false)))
      let preserved = harness.paths.instanceLogDir(instance.id)
        .appending(path: VMInstanceLayout.serialLogName)
      #expect(try String(contentsOf: preserved, encoding: .utf8) == "boot log\n")
      await agent.stop()
    }
  }

  /// The whole point of the "never block teardown" rule: a guest that refuses to produce its
  /// diagnostics is stopped and deleted exactly as it would otherwise have been.
  @Test func aFailingCollectionDoesNotPreventStopAndDelete() async throws {
    try await withHarness { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatusSequence = [.online, .busy, .exited].map {
        RunnerStatus(state: $0, pid: 4_242)
      }
      script.failures[.exec] = RPCErrorPayload(
        code: "DEADLINE_EXCEEDED", message: "the collection command timed out")
      let (instance, agent) = try await harness.idleInstance(script: script)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      #expect(try await harness.awaitTerminal(session.id).state == .completed)
      try await waitUntil("the ephemeral instance to be deleted anyway") {
        try await harness.record(instance.id).state == .deleted
      }

      #expect(await agent.callCount(.exec) == 1)
      // No partial archive is left behind for an operator to mistake for real evidence.
      #expect(!FileManager.default.fileExists(
        atPath: harness.paths.instanceDiagnosticsDir(instance.id)
          .appending(path: InstanceManager.diagnosticsArchiveName).path(percentEncoded: false)))
      await agent.stop()
    }
  }

  @Test func collectionIsSkippedWhenTheConfigurationTurnsItOff() async throws {
    var configuration = M2Harness.configuration()
    configuration.logging.collectRunnerDiagnostics = false
    try await withHarness(configuration: configuration) { harness in
      harness.stubGitHub()
      try await harness.markScopeHealthy()
      var script = FakeGuestAgent.Script()
      script.runnerStatusSequence = [.online, .busy, .exited].map {
        RunnerStatus(state: $0, pid: 4_242)
      }
      let (instance, agent) = try await harness.idleInstance(script: script)

      let session = try await harness.runners.startSession(instanceId: instance.id)
      try await harness.awaitTerminal(session.id)
      try await waitUntil("the ephemeral instance to be deleted") {
        try await harness.record(instance.id).state == .deleted
      }

      #expect(await agent.callCount(.exec) == 0)
      await agent.stop()
    }
  }
}
