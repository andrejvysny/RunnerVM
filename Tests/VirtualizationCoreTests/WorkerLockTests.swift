import Foundation
import Testing
@testable import VirtualizationCore

@Suite struct WorkerLockTests {
  /// Holds an `fcntl` write lock in a child process until its stdin closes, and announces
  /// acquisition on stdout so the parent never has to sleep.
  ///
  /// A child is unavoidable: POSIX record locks are per-process, so a second `acquire` inside the
  /// test runner would silently succeed.
  private static let holderScript = """
    import fcntl, sys
    handle = open(sys.argv[1], 'a+b')
    fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.stdout.write('locked\\n')
    sys.stdout.flush()
    sys.stdin.read()
    """

  private func startHolder(_ url: URL) throws -> (process: Process, stdin: FileHandle)? {
    let python = "/usr/bin/python3"
    guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-c", Self.holderScript, url.path]
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardInput = input
    try process.run()
    var seen = Data()
    while !seen.contains(UInt8(ascii: "\n")) {
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else { return nil }
      seen.append(chunk)
    }
    #expect(String(decoding: seen, as: UTF8.self) == "locked\n")
    return (process, input.fileHandleForWriting)
  }

  @Test func acquiresAndReportsHolderAcrossProcesses() throws {
    let directory = try Scratch.makeDirectory("lock")
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).workerLock
    guard let holder = try startHolder(url) else { return }

    #expect(WorkerLock.holder(of: url) == holder.process.processIdentifier)
    #expect(throws: WorkerLockError.held(pid: holder.process.processIdentifier)) {
      try WorkerLock.acquire(instanceDirectory: directory)
    }

    holder.stdin.closeFile()
    holder.process.waitUntilExit()

    let lock = try WorkerLock.acquire(instanceDirectory: directory)
    #expect(lock.descriptor >= 0)
    #expect(lock.url.lastPathComponent == "worker.lock")
    // A process never conflicts with its own record locks, so F_GETLK reports no holder here.
    #expect(WorkerLock.holder(of: url) == nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")
  }

  @Test func reportsNoHolderForAnUnlockedFile() throws {
    let directory = try Scratch.makeDirectory("lock-free")
    defer { Scratch.remove(directory) }
    let url = VMRuntimePaths(directory: directory).workerLock
    #expect(WorkerLock.holder(of: url) == nil)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    #expect(WorkerLock.holder(of: url) == nil)
  }

  @Test func createsLockFileWithOwnerOnlyPermissions() throws {
    let directory = try Scratch.makeDirectory("lock-mode")
    defer { Scratch.remove(directory) }
    let lock = try WorkerLock.acquire(instanceDirectory: directory)
    #expect(lock.descriptor >= 0)
    let attributes = try FileManager.default.attributesOfItem(atPath: lock.url.path)
    #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
  }
}
