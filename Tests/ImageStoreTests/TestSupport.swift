import Foundation
import RunnerCore
@testable import ImageStore

/// One isolated store rooted in the system temp directory, which is APFS on every supported Mac —
/// the clone paths under test need a real clone-capable volume.
final class TempStore {
  static let diskBytes: UInt64 = 32 * 1024 * 1024
  /// Fixed so image digests are reproducible across runs.
  static let createdAt = Date(timeIntervalSince1970: 1_756_000_000)

  let root: URL
  let paths: RunnerPaths
  let images: ImageStore

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "imagestore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = RunnerPaths(rootDir: root, runtimeDir: root.appending(path: "run", directoryHint: .isDirectory))
    images = ImageStore(paths: paths)
  }

  deinit {
    try? FileSystem.removeIfPresent(root)
  }

  func instanceStore(
    allowFullCopy: Bool = false, now: @escaping @Sendable () -> Date = { Date() }
  ) -> InstanceStore {
    InstanceStore(paths: paths, images: images, allowFullCopy: allowFullCopy, now: now)
  }

  func buildStore(allowFullCopy: Bool = false) -> BuildStore {
    BuildStore(paths: paths, images: images, allowFullCopy: allowFullCopy)
  }

  // MARK: - Fixtures

  /// Sparse raw disk: a few real bytes, then a hole out to the virtual size.
  @discardableResult
  func makeSparseDisk(
    named name: String, virtualBytes: UInt64 = TempStore.diskBytes, marker: UInt8 = 0x42
  ) throws -> URL {
    let url = root.appending(path: name)
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data(repeating: marker, count: 8))
    try handle.truncate(atOffset: virtualBytes)
    return url
  }

  static func linuxMetadata(
    virtualDiskSizeBytes: UInt64 = TempStore.diskBytes, runnerVersion: String? = nil
  ) -> ImageMetadata {
    ImageMetadata(
      os: .linux, virtualDiskSizeBytes: virtualDiskSizeBytes, runnerVersion: runnerVersion,
      createdAt: createdAt, boot: ImageMetadata.Boot(type: .efi)
    )
  }

  static func macOSMetadata(hardwareModel: String?) -> ImageMetadata {
    ImageMetadata(
      os: .macos, virtualDiskSizeBytes: diskBytes, createdAt: createdAt,
      boot: ImageMetadata.Boot(type: .macos),
      macos: hardwareModel.map { ImageMetadata.MacOSPlatform(hardwareModel: $0, sourceVersion: "15.0") }
    )
  }

  // MARK: - Inspection helpers

  func blobFiles() throws -> [URL] {
    let root = paths.imageBlobsDir.appending(path: "sha256", directoryHint: .isDirectory)
    guard FileSystem.exists(root),
          let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { !FileSystem.isDirectory($0) }
  }

  func stagingChildren(of directory: URL) throws -> [URL] {
    let staging = directory.appending(path: ".tmp", directoryHint: .isDirectory)
    guard FileSystem.exists(staging) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
  }

  func mode(of url: URL) throws -> mode_t {
    try FileSystem.fileInfo(url).st_mode & 0o777
  }

  func overwrite(_ url: URL, at offset: UInt64, with bytes: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: bytes)
  }
}

/// Stand-in for `VMInstanceSpec`, which lives in VirtualizationCore and must not be imported here.
struct SampleSpec: Encodable, Sendable {
  var instanceId: String
  var cpuCount: Int = 4
  var memoryBytes: UInt64 = 8 << 30
}

struct SpecEncodingFailure: Error {}

/// Fails after the disk clone has already happened, exercising the mid-way failure path.
struct ThrowingSpec: Encodable, Sendable {
  func encode(to encoder: any Encoder) throws {
    throw SpecEncodingFailure()
  }
}
