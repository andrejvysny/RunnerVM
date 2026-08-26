import Foundation
@testable import OCIRegistry
import RunnerCore

/// Scratch directory removed when the test's reference goes away.
final class TempDirectory {
  let url: URL

  init(_ label: String) throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "ociregistry-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  func appending(_ name: String) -> URL {
    url.appending(path: name)
  }

  func directory(_ name: String) throws -> URL {
    let child = url.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    return child
  }
}

enum Fixtures {
  /// Fixed so image digests are reproducible across runs.
  static let createdAt = Date(timeIntervalSince1970: 1_756_000_000)

  /// Sparse raw disk: islands of data separated by holes, then truncated to the virtual size.
  @discardableResult
  static func makeSparseDisk(
    at url: URL, virtualBytes: UInt64, islands: [(offset: UInt64, bytes: Int)]
  ) throws -> URL {
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    for (index, island) in islands.enumerated() {
      try handle.seek(toOffset: island.offset)
      try handle.write(contentsOf: pattern(seed: UInt8(index &+ 1), count: island.bytes))
    }
    try handle.truncate(atOffset: virtualBytes)
    return url
  }

  /// Non-uniform so LZ4 cannot collapse an island to nothing and hide a reassembly bug.
  static func pattern(seed: UInt8, count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var value = UInt32(seed) &* 2_654_435_761
    for index in 0 ..< count {
      value = value &* 1_664_525 &+ 1_013_904_223
      bytes[index] = UInt8(truncatingIfNeeded: value >> 16)
    }
    return Data(bytes)
  }

  static func linuxMetadata(virtualDiskSizeBytes: UInt64) -> ImageMetadata {
    ImageMetadata(
      os: .linux, virtualDiskSizeBytes: virtualDiskSizeBytes, runnerVersion: "2.320.0",
      createdAt: createdAt, boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(docker: true, ssh: true)
    )
  }

  /// Blocks actually committed, which for a sparse file is far below its length.
  static func allocatedBytes(at url: URL) throws -> UInt64 {
    var info = stat()
    guard stat(url.path(percentEncoded: false), &info) == 0 else { return 0 }
    return UInt64(info.st_blocks) * 512
  }

  static func fileBytes(at url: URL) throws -> Data {
    try Data(contentsOf: url, options: .mappedIfSafe)
  }
}
