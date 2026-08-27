import Foundation
import ImageStore
import OCIRegistry
import RunnerCore
import Synchronization

@testable import Orchestration

/// Keychain that lives in memory, so `registry login` is exercised for real without touching the
/// developer's login keychain.
final class InMemoryRegistryKeychain: RegistryCredentialStore {
  private let items = Mutex<[String: RegistryCredential]>([:])

  func internetPassword(server: String) throws -> RegistryCredential? {
    items.withLock { $0[server] }
  }

  func store(_ credential: RegistryCredential, server: String) throws {
    items.withLock { $0[server] = credential }
  }

  @discardableResult
  func remove(server: String) throws -> Bool {
    items.withLock { $0.removeValue(forKey: server) != nil }
  }
}

/// Hands `ImageManager` a client bound to one `FakeRegistry`; anything else is "no such registry",
/// which is also what the daemon would see for a typo'd host.
struct FakeRegistryClientFactory: RegistryClientFactory {
  let registry: FakeRegistry
  let credentials: any RegistryCredentialProvider

  func client(for registry: String) async throws -> RegistryClient {
    guard registry == self.registry.host else {
      throw RegistryError.notFound(resource: "registry \(registry)")
    }
    return self.registry.makeClient(credentials: credentials)
  }
}

/// Publishes a RunnerVM artifact into a `FakeRegistry` and remembers what it is made of, so a test
/// can assert on exactly which blobs a pull fetched.
struct PublishedImage {
  let reference: OCIReference
  /// The registry manifest digest — the identity a pull deduplicates and stages on.
  let manifestDigest: ImageDigest
  let metadata: ImageMetadata
  let diskURL: URL
  let nvramURL: URL?
  let configDigest: String
  let chunkDigests: [String]
  let nvramDigest: String?

  /// 32 MiB of sparse disk in 8 MiB chunks: four independently resumable pieces, and nothing that
  /// LZ4 can collapse to nothing.
  static let diskBytes: UInt64 = 32 << 20
  static let chunkBytes = 8 << 20

  /// - Parameter guestAgent: what the published metadata declares. The default `true` matches a
  ///   real RunnerVM image; `false` publishes the kind of inspection-only artifact `vm create`
  ///   must refuse (spec §58).
  static func publish(
    into fake: FakeRegistry, at directory: URL, repository: String = "acme/runners/ubuntu-24",
    tag: String = "stable", withNVRAM: Bool = false, seed: UInt8 = 1, guestAgent: Bool = true
  ) async throws -> PublishedImage {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = try makeDisk(at: directory.appending(path: "disk.img"), seed: seed)
    var nvram: URL?
    if withNVRAM {
      let url = directory.appending(path: "nvram.bin")
      try pattern(seed: seed &+ 40, count: 64 << 10).write(to: url)
      nvram = url
    }
    let metadata = ImageMetadata(
      os: .linux, architecture: "arm64", virtualDiskSizeBytes: diskBytes,
      guestAgentVersion: guestAgent ? "0.1.0" : nil,
      createdAt: Date(timeIntervalSince1970: 1_756_000_000 + Double(seed)),
      boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(guestAgent: guestAgent))
    let reference = try fake.reference(repository, tag: tag)
    let staging = directory.appending(path: "push", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let pushed = try await RunnerVMImageTransfer.push(
      diskURL: disk, nvramURL: nvram, metadata: metadata, to: reference,
      registry: fake.makeClient(), staging: staging, chunkBytes: chunkBytes, concurrency: 2)
    let layers = pushed.manifest.layers
    return PublishedImage(
      reference: reference, manifestDigest: pushed.manifestDigest, metadata: metadata,
      diskURL: disk, nvramURL: nvram,
      configDigest: pushed.manifest.config.digest,
      chunkDigests: layers.filter { $0.mediaType == RunnerVMMediaType.diskChunk }.map(\.digest),
      nvramDigest: layers.first { $0.mediaType != RunnerVMMediaType.diskChunk }?.digest)
  }

  /// Blob GETs the fake served for the disk chunks only — the config blob is fetched by every
  /// `inspect`, so counting it would hide whether a transfer was actually deduplicated.
  func chunkFetches(_ fake: FakeRegistry) -> Int {
    fake.requests("GET", containing: "/blobs/").count { request in
      chunkDigests.contains { request.path.hasSuffix($0) }
    }
  }

  static func makeDisk(at url: URL, seed: UInt8) throws -> URL {
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    for (index, offset) in [UInt64(0), 9 << 20, 17 << 20, 25 << 20].enumerated() {
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: pattern(seed: seed &+ UInt8(index), count: 256 << 10))
    }
    try handle.truncate(atOffset: diskBytes)
    return url
  }

  private static func pattern(seed: UInt8, count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var value = UInt32(seed) &* 2_654_435_761
    for index in 0 ..< count {
      value = value &* 1_664_525 &+ 1_013_904_223
      bytes[index] = UInt8(truncatingIfNeeded: value >> 16)
    }
    return Data(bytes)
  }
}

extension M2Harness {
  /// Imports the same bytes into a throwaway store, giving the content digest a registry round
  /// trip must reproduce (spec P9).
  func mirrorImport(_ published: PublishedImage) async throws -> ImageDigest {
    let root = tree.root.appending(path: "mirror", directoryHint: .isDirectory)
    let store = ImageStore(
      paths: RunnerPaths(
        rootDir: root, runtimeDir: root.appending(path: "run", directoryHint: .isDirectory)))
    return try await store.importLocal(
      disk: published.diskURL, nvram: published.nvramURL, metadata: published.metadata).digest
  }

  func stagingDirectory(for manifestDigest: ImageDigest) -> URL {
    paths.imagesDir
      .appending(path: ".tmp", directoryHint: .isDirectory)
      .appending(path: ImageManager.pullStagingName(for: manifestDigest), directoryHint: .isDirectory)
  }
}
