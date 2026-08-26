import Foundation
import Logging
import RunnerCore
import Testing

@testable import RunnerLogging

/// The correlation keys added in M14, and the process-wide context `DaemonRuntime` publishes so
/// every line carries `host_id` without the call sites knowing it.
///
/// `.serialized` because `LogContext.global` is process state: two of these running at once would
/// see each other's host id.
@Suite(.serialized) struct LogContextGlobalTests {
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
      lock.lock()
      storage.append(line)
      lock.unlock()
    }

    var lines: [String] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
  }

  private static func emit(
    handlerMetadata: Logger.Metadata = [:], callSite: Logger.Metadata? = nil
  ) throws -> [String: Any] {
    let collector = Collector()
    var handler = JSONLogHandler(label: "daemon", logLevel: .trace, sink: collector.append)
    handler.metadata = handlerMetadata
    handler.log(event: LogEvent(
      level: .info, message: "hello", metadata: callSite, source: nil, file: #fileID,
      function: #function, line: #line))
    return try #require(
      try JSONSerialization.jsonObject(with: Data(collector.lines[0].utf8)) as? [String: Any])
  }

  @Test func theNewCorrelationKeysAreBuilt() {
    let metadata = Logger.Metadata.context(
      host: HostID(rawValue: "h1"),
      scaleSetID: "ss-1",
      githubRunnerID: 99,
      githubRunnerName: "rvm-linux-abc",
      githubRequestID: "REQ-7")
    #expect(metadata["host_id"] == .string("h1"))
    #expect(metadata["scale_set_id"] == .string("ss-1"))
    #expect(metadata["github_runner_name"] == .string("rvm-linux-abc"))
    #expect(metadata["github_request_id"] == .string("REQ-7"))
    guard case .stringConvertible(let runner)? = metadata["github_runner_id"] else {
      Issue.record("expected github_runner_id to be stringConvertible")
      return
    }
    #expect(runner.description == "99")
  }

  @Test func theGlobalContextReachesEveryEntry() throws {
    LogContext.clearGlobal()
    defer { LogContext.clearGlobal() }
    LogContext.setGlobalHost(HostID(rawValue: "host-42"))

    #expect(try Self.emit()["host_id"] as? String == "host-42")
  }

  /// Lowest priority by design: a call site that knows a more specific value must win.
  @Test func aCallSiteOverridesTheGlobalContext() throws {
    LogContext.clearGlobal()
    defer { LogContext.clearGlobal() }
    LogContext.setGlobalHost(HostID(rawValue: "host-42"))

    #expect(try Self.emit(callSite: ["host_id": .string("other")])["host_id"] as? String == "other")
    #expect(try Self.emit(handlerMetadata: ["host_id": .string("handler")])["host_id"] as? String
      == "handler")
  }

  @Test func clearingTheGlobalContextRemovesItFromLaterEntries() throws {
    LogContext.setGlobalHost(HostID(rawValue: "host-42"))
    LogContext.clearGlobal()

    #expect(try Self.emit()["host_id"] == nil)
  }

  /// The redactor runs after the merge, so a secret placed in the process-wide context is still
  /// caught rather than bypassing it.
  @Test func theGlobalContextIsRedactedLikeAnyOtherMetadata() throws {
    LogContext.clearGlobal()
    defer { LogContext.clearGlobal() }
    LogContext.setGlobal(["registry_password": .string("hunter2")])

    #expect(try Self.emit()["registry_password"] as? String == "[REDACTED:metadata-key]")
  }
}
