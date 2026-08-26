import Foundation
import Testing

@testable import RunnerLogging

/// `RotatingFileSink` is the only thing standing between a full disk and a daemon that cannot log,
/// so these cover the four properties that matter: it appends, it rotates, it caps the archive
/// count, and it never propagates an I/O failure.
@Suite struct RotatingFileSinkTests {
  /// A temp directory removed when the test returns, whether it throws or not.
  private static func withTemporaryDirectory(
    _ body: (URL) throws -> Void
  ) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "rvm-sink-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  private static func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  @Test func appendsOneLinePerWriteAndCreatesTheParentDirectory() throws {
    try Self.withTemporaryDirectory { root in
      // The directory does not exist yet: the sink has to create it, exactly as it must on a
      // fresh host where nothing has written to logs/runnerd/ before.
      let url = root.appending(path: "nested/deeper/runnerd.log")
      let sink = try RotatingFileSink(url: url, reopenOnHangup: false)
      sink.write("{\"a\":1}")
      sink.write("{\"a\":2}")
      sink.close()

      #expect(Self.read(url) == "{\"a\":1}\n{\"a\":2}\n")
      #expect(sink.droppedLines == 0)
    }
  }

  @Test func reopeningTheSamePathAppendsRatherThanTruncating() throws {
    try Self.withTemporaryDirectory { root in
      let url = root.appending(path: "runnerd.log")
      let first = try RotatingFileSink(url: url, reopenOnHangup: false)
      first.write("first")
      first.close()

      let second = try RotatingFileSink(url: url, reopenOnHangup: false)
      second.write("second")
      second.close()

      #expect(Self.read(url) == "first\nsecond\n")
    }
  }

  @Test func rotatesOnceTheLiveFileReachesMaxSize() throws {
    try Self.withTemporaryDirectory { root in
      let url = root.appending(path: "runnerd.log")
      // 5 bytes per line ("abcd" + newline); the third line crosses a 10-byte ceiling.
      let sink = try RotatingFileSink(
        url: url, options: .init(maxSizeBytes: 10, maxFiles: 3), reopenOnHangup: false)
      sink.write("abcd")
      sink.write("efgh")
      sink.write("ijkl")
      sink.close()

      #expect(Self.read(url) == "ijkl\n")
      #expect(Self.read(sink.rotatedURL(1)) == "abcd\nefgh\n")
      #expect(!FileManager.default.fileExists(
        atPath: sink.rotatedURL(2).path(percentEncoded: false)))
    }
  }

  @Test func keepsAtMostMaxFilesArchivesAndDropsTheOldest() throws {
    try Self.withTemporaryDirectory { root in
      let url = root.appending(path: "runnerd.log")
      // Lines are 4 bytes each, so every second one crosses the 7-byte ceiling: three archives
      // are produced but only two may survive.
      let sink = try RotatingFileSink(
        url: url, options: .init(maxSizeBytes: 7, maxFiles: 2), reopenOnHangup: false)
      for line in ["one", "two", "six", "ten", "sun", "sky", "day"] { sink.write(line) }
      sink.close()

      let manager = FileManager.default
      let children = try manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))
      #expect(Set(children) == ["runnerd.log", "runnerd.log.1", "runnerd.log.2"])
      // Newest first: the live file holds the tail, `.1` the generation before it, and the
      // oldest generation ("one"/"two") is gone.
      #expect(Self.read(url) == "day\n")
      #expect(Self.read(sink.rotatedURL(1)) == "sun\nsky\n")
      #expect(Self.read(sink.rotatedURL(2)) == "six\nten\n")
    }
  }

  @Test func sighupReopensThePathAfterAnExternalRename() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "rvm-sink-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "runnerd.log")
    let sink = try RotatingFileSink(url: url)
    defer { sink.close() }
    sink.write("before")

    // Exactly what newsyslog does: rename the live file out from under the open descriptor.
    let archived = root.appending(path: "runnerd.log.external")
    try FileManager.default.moveItem(at: url, to: archived)
    #expect(kill(getpid(), SIGHUP) == 0)

    // The handler runs on a dispatch queue, so poll rather than assume it has already fired.
    var reopened = false
    for _ in 0..<200 {
      sink.write("after")
      if Self.read(url).contains("after") {
        reopened = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reopened)
    // The renamed file keeps everything written before the handler ran and nothing after: the
    // poll above deliberately writes into the still-open descriptor until the signal lands, so
    // the only guarantee that matters is that the renamed file stops growing once it has.
    let archivedAfter = Self.read(archived)
    #expect(archivedAfter.hasPrefix("before\n"))
    sink.write("last")
    #expect(Self.read(archived) == archivedAfter)
    #expect(Self.read(url).hasSuffix("last\n"))
  }

  @Test func countsDropsInsteadOfThrowingWhenTheFileCannotBeWritten() throws {
    try Self.withTemporaryDirectory { root in
      let url = root.appending(path: "runnerd.log")
      let sink = try RotatingFileSink(url: url, reopenOnHangup: false)
      let before = RotatingFileSink.totalDroppedLines
      // `close()` is terminal, which is the one deterministic way to make every later write fail
      // without depending on filesystem permissions the test runner may or may not have.
      sink.close()
      sink.write("lost")
      sink.write("also lost")

      #expect(sink.droppedLines == 2)
      #expect(RotatingFileSink.totalDroppedLines == before + 2)
    }
  }

  @Test func openingAnImpossiblePathThrowsSoTheCallerCanFallBackToStderr() throws {
    // A path whose parent is an existing *file* can never be a directory.
    try Self.withTemporaryDirectory { root in
      let blocker = root.appending(path: "blocker")
      try Data("x".utf8).write(to: blocker)
      #expect(throws: LogSinkError.self) {
        _ = try RotatingFileSink(url: blocker.appending(path: "runnerd.log"))
      }
    }
  }

  @Test func theSinkClosureIsUsableAsAJSONLogHandlerSink() throws {
    try Self.withTemporaryDirectory { root in
      let url = root.appending(path: "runnerd.log")
      let sink = try RotatingFileSink(url: url, reopenOnHangup: false)
      let tee = LoggingSystemBootstrap.tee([sink.sink()])
      tee("{\"message\":\"hello\"}")
      sink.close()
      #expect(Self.read(url) == "{\"message\":\"hello\"}\n")
    }
  }
}
