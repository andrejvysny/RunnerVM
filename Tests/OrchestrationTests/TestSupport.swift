import ConfigLoader
import Foundation
import RunnerCore

@testable import Orchestration

/// Short root under /tmp: the daemon socket lives inside it and `sun_path` holds 104 bytes.
struct TempTree {
  let root: URL

  init() throws {
    root = URL(
      fileURLWithPath: "/tmp/rvm-orch-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  var paths: RunnerPaths {
    RunnerPaths(
      rootDir: root.appending(path: "state", directoryHint: .isDirectory),
      runtimeDir: root.appending(path: "sock", directoryHint: .isDirectory))
  }

  func file(_ name: String, contents: String) throws -> URL {
    let url = root.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// Stand-in for the signed `vmworker probe` binary: prints canned `HostCapabilities` JSON.
  func vmworkerStub() throws -> URL {
    let url = root.appending(path: "vmworker-stub")
    try Data(Self.stubScript.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
  }

  /// `ImageStore` publishes image blobs as a read-only tree (files `0o444`, directories `0o555`,
  /// see `Sources/ImageStore/FileSystem.swift`) so a build can't mutate a sealed image by
  /// accident. Deleting through such a directory needs the owner-write bit `removeItem` doesn't
  /// have, so it fails with `EPERM`/"Directory not empty" -- silently, because this is `try?` --
  /// and leaves the whole tree behind as an orphaned `/tmp/rvm-orch-*` directory. Restore
  /// owner-write everywhere under `root` first.
  func remove() {
    makeTreeWritable(root)
    try? FileManager.default.removeItem(at: root)
  }

  private func makeTreeWritable(_ url: URL) {
    let fm = FileManager.default
    restoreOwnerWrite(at: url)
    guard
      let enumerator = fm.enumerator(
        at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
    else { return }
    for case let child as URL in enumerator {
      restoreOwnerWrite(at: child)
    }
  }

  private func restoreOwnerWrite(at url: URL) {
    let fm = FileManager.default
    let path = url.path(percentEncoded: false)
    guard let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    else { return }
    try? fm.setAttributes([.posixPermissions: mode.uint16Value | 0o200], ofItemAtPath: path)
  }

  private static let stubScript = """
    #!/bin/sh
    cat <<'JSON'
    {
      "virtualizationSupported": true,
      "architecture": "arm64",
      "hostOSVersion": "15.4.0",
      "logicalCPUCount": 12,
      "physicalMemoryBytes": 68719476736,
      "minimumAllowedCPUCount": 1,
      "maximumAllowedCPUCount": 12,
      "minimumAllowedMemoryBytes": 134217728,
      "maximumAllowedMemoryBytes": 68719476736,
      "nestedVirtualizationSupported": false,
      "macOSGuestLimit": 2
    }
    JSON
    """
}

func exampleConfiguration() throws -> RunnerConfiguration {
  try ConfigLoader.load(yaml: ExampleConfig.example)
}

/// A second linux profile alongside the example's `ubuntu-24`, for tests that exercise
/// profile-level add/remove/update diffing against the applier. (The shipped example now carries
/// a single profile since this build rejects macOS guests; see `ExampleConfig`.)
private let secondExampleProfile = RunnerProfileConfig(
  name: "ubuntu-22",
  scope: "engineering",
  image: "ghcr.io/acme/runners/ubuntu-22:stable",
  guestOS: .linux,
  limits: ProfileLimits(maxInstances: 4)
)

func exampleWithSecondProfile() throws -> RunnerConfiguration {
  var config = try exampleConfiguration()
  config.profiles.append(secondExampleProfile)
  return config
}

/// Holds a real `fcntl` write lock on a file until `release()` (or the process exits).
///
/// A separate process is unavoidable: POSIX record locks are per-process, so a lock taken inside
/// the test runner is invisible to `WorkerLock.holderPID` running in the same runner. Copied from
/// `VirtualizationCoreTests.WorkerLockTests` rather than shared, because test targets cannot import
/// each other.
///
/// `start` returns `nil` when the host has no `/usr/bin/python3`, which lets a test skip instead of
/// failing on a machine without it.
final class LockHolder: @unchecked Sendable {
  /// Marks one end of a `Pipe` close-on-exec.
  ///
  /// Without this, *any* other process this test bundle spawns while a holder is alive inherits
  /// this pipe's write end, and the holder's `sys.stdin.read()` then never sees EOF -- so
  /// `release()` blocks in `waitUntilExit()`, on the main actor, forever. Two suites that both
  /// hold locks run concurrently under `swift test --parallel` (`.serialized` only orders a suite
  /// against itself), which is exactly when that happens. `posix_spawn`'s `dup2` file actions
  /// clear the flag on the descriptors the intended child actually gets, so it still works.
  private static func closeOnExec(_ handle: FileHandle) {
    _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
  }

  private let process: Process
  private let stdin: FileHandle

  private static let script = """
    import fcntl, sys
    handle = open(sys.argv[1], 'a+b')
    fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.stdout.write('locked\\n')
    sys.stdout.flush()
    sys.stdin.read()
    """

  private init(process: Process, stdin: FileHandle) {
    self.process = process
    self.stdin = stdin
  }

  /// Blocks until the child announces on stdout that it holds the lock, so no caller ever sleeps.
  static func start(_ url: URL) throws -> LockHolder? {
    let python = "/usr/bin/python3"
    guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-c", script, url.path(percentEncoded: false)]
    let output = Pipe()
    let input = Pipe()
    for handle in [
      output.fileHandleForReading, output.fileHandleForWriting,
      input.fileHandleForReading, input.fileHandleForWriting,
    ] {
      closeOnExec(handle)
    }
    process.standardOutput = output
    process.standardInput = input
    try process.run()
    var seen = Data()
    while !seen.contains(UInt8(ascii: "\n")) {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else { return nil }
      seen.append(chunk)
    }
    return LockHolder(process: process, stdin: input.fileHandleForWriting)
  }

  var isRunning: Bool { process.isRunning }

  /// Closing stdin ends the child's `stdin.read()`, which drops the lock as the process exits;
  /// `terminate()` follows as a backstop, in case a descriptor this pipe leaked elsewhere is
  /// holding the write end open.
  ///
  /// Deliberately **not** `Process.waitUntilExit()`. That call runs the run loop of whichever
  /// thread reaches it and waits for a notification posted to the run loop of the thread that
  /// called `run()` -- under Swift concurrency an `await` between the two moves the caller to a
  /// different cooperative thread, and the wait then blocks forever even though the child is long
  /// gone. `isRunning` is driven by Foundation's `DISPATCH_SOURCE_TYPE_PROC` reaper instead, which
  /// is thread-independent, so polling it is both correct and bounded.
  func release() {
    guard process.isRunning else { return }
    stdin.closeFile()
    process.terminate()
    var attempts = 0
    while process.isRunning, attempts < Self.exitPollAttempts {
      usleep(Self.exitPollMicroseconds)
      attempts += 1
    }
  }

  private static let exitPollAttempts = 500
  private static let exitPollMicroseconds: UInt32 = 10_000
}
