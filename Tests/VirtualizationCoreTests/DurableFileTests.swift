import Darwin
import Foundation
import Testing

@testable import VirtualizationCore

/// `DurableFile` is the primitive under `machine-identifier.bin`, so it has to be correct
/// independently of that caller: no temporary left behind, no window where the file is readable by
/// anyone else, and a failed write that leaves the previous contents exactly as they were.
///
/// The `fsync` calls themselves are not observable from a test — only a real power loss would
/// distinguish them — so what is asserted here is everything around them.
@Suite struct DurableFileTests {
  private func scratch() throws -> URL { try Scratch.makeDirectory("durable") }

  @Test func writesTheBytesAtTheRequestedModeAndLeavesNoTemporary() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = directory.appending(path: "value.bin")

    try DurableFile.atomicReplace(Data([1, 2, 3, 4]), at: url, mode: 0o600)

    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["value.bin"])
  }

  /// A restrictive mode has to survive a permissive umask: the identity file is 0600 whatever the
  /// daemon's process umask happens to be when it starts a worker.
  @Test func theModeIsNotWidenedByTheProcessUmask() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let previous = umask(0)
    defer { umask(previous) }
    let url = directory.appending(path: "masked.bin")

    try DurableFile.atomicReplace(Data([7]), at: url, mode: 0o600)

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func replacingAnExistingFileKeepsNeitherTheOldBytesNorATemporary() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = directory.appending(path: "value.bin")
    try DurableFile.atomicReplace(Data([0xAA]), at: url)

    try DurableFile.atomicReplace(Data([0xBB, 0xCC]), at: url)

    #expect(try Data(contentsOf: url) == Data([0xBB, 0xCC]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["value.bin"])
  }

  /// The temporary is created `O_EXCL` under a name no other run can be holding, so a leftover
  /// from a crashed process is never adopted and never blocks the next write.
  @Test func aLeftoverTemporaryFromAnEarlierRunDoesNotBlockTheWrite() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = directory.appending(path: "value.bin")
    let stale = directory.appending(path: "value.bin.tmp-DEADBEEF")
    try Data("stale".utf8).write(to: stale)

    try DurableFile.atomicReplace(Data([9]), at: url)

    #expect(try Data(contentsOf: url) == Data([9]))
    // The stale file is *not* cleaned up here — that is retention's job, not this primitive's —
    // but it must not have been reused or renamed over the destination.
    #expect(try Data(contentsOf: stale) == Data("stale".utf8))
  }

  @Test func aWriteIntoAnUnwritableDirectoryLeavesThePreviousContents() throws {
    let directory = try scratch()
    defer {
      chmod(directory.path, 0o755)
      Scratch.remove(directory)
    }
    let url = directory.appending(path: "value.bin")
    try DurableFile.atomicReplace(Data([1]), at: url)
    chmod(directory.path, 0o500)

    #expect(throws: DurableFileError.self) {
      try DurableFile.atomicReplace(Data([2]), at: url)
    }

    chmod(directory.path, 0o755)
    #expect(try Data(contentsOf: url) == Data([1]))
  }

  /// Larger than any single `write(2)` is likely to take in one go, so the loop actually runs more
  /// than once on a short write.
  @Test func writesPayloadsLargerThanOneWriteSyscall() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = directory.appending(path: "big.bin")
    let payload = Data((0..<(4 << 20)).map { UInt8($0 % 251) })

    try DurableFile.atomicReplace(payload, at: url)

    #expect(try Data(contentsOf: url) == payload)
  }

  @Test func writesAnEmptyPayloadWithoutSpinning() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let url = directory.appending(path: "empty.bin")

    try DurableFile.atomicReplace(Data(), at: url)

    #expect(try Data(contentsOf: url).isEmpty)
  }
}
