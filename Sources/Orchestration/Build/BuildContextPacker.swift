import CryptoKit
import Foundation
import ImageBuild
import RunnerCore

/// The packed build context: a `context.img` ISO holding one `context.tar`, plus the identity the
/// build row records.
public struct PackedContext: Sendable, Hashable {
  public var image: URL
  public var bytes: UInt64
  public var sha256: String
}

/// Turns a context directory into the read-only ISO the builder VM mounts (N2).
///
/// Packed **synchronously inside `image.build`**, before the RPC returns: the caller's tree is
/// theirs to keep editing the moment it answers, and a context hashed at that instant is the one
/// the build row can honestly claim to have built from.
///
/// The walk is deliberately paranoid. The tar lands inside a VM that runs recipe-authored commands
/// as root, so anything that could make extraction reach outside `contextRoot` -- a symlink
/// resolving out of the context, a device node, a FIFO, a socket, a hard link shared with a file
/// elsewhere on the host -- is refused (`BUILD_CONTEXT_UNSAFE_ENTRY`) rather than filtered.
public enum BuildContextPacker {
  public static let tarName = "context.tar"
  public static let volumeName = "rvmctx"

  private static let tar = "/usr/bin/tar"
  private static let hdiutil = "/usr/bin/hdiutil"

  public static func pack(
    context: URL, ignore: RecipeIgnore, into destination: URL, maxBytes: UInt64,
    staging: URL, runner: any ProcessRunner
  ) async throws -> PackedContext {
    let root = context.resolvingSymlinksInPath()
    let entries = try walk(root: root, ignore: ignore, maxBytes: maxBytes)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let payload = staging.appending(path: "payload", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

    let list = staging.appending(path: "files.txt")
    try Data(entries.paths.joined(separator: "\n").appending("\n").utf8).write(to: list)
    let tarball = payload.appending(path: tarName)
    try await runner.runChecked(tar, [
      "-cf", tarball.path(percentEncoded: false),
      "-C", root.path(percentEncoded: false),
      "-T", list.path(percentEncoded: false), "--no-recursion",
    ])
    let digest = try SHA256Digest.file(at: tarball)
    let iso = staging.appending(path: "context.iso")
    try? FileManager.default.removeItem(at: iso)
    try await runner.runChecked(hdiutil, [
      "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName,
      "-o", iso.path(percentEncoded: false), payload.path(percentEncoded: false),
    ])
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: iso, to: destination)
    return PackedContext(image: destination, bytes: entries.bytes, sha256: digest)
  }

  // MARK: - Walk

  struct Walked {
    var paths: [String]
    var bytes: UInt64
  }

  static func walk(root: URL, ignore: RecipeIgnore, maxBytes: UInt64) throws -> Walked {
    guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
      throw ImageBuildError.contextUnreadable(path: root.path(percentEncoded: false))
    }
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceTypeKey,
      .linkCountKey,
    ]
    guard let walker = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: Array(keys),
      options: [.producesRelativePathURLs]
    ) else {
      throw ImageBuildError.contextUnreadable(path: root.path(percentEncoded: false))
    }
    var paths: [String] = []
    var sizes: [(String, UInt64)] = []
    var total: UInt64 = 0
    for case let url as URL in walker {
      let relative = Self.relativePath(of: url, under: root)
      guard !relative.isEmpty else { continue }
      let values = try url.resourceValues(forKeys: keys)
      if values.isDirectory == true {
        if ignore.excludes(relativePath: relative, isDirectory: true) { walker.skipDescendants() }
        continue
      }
      if ignore.excludes(relativePath: relative, isDirectory: false) { continue }
      let size = try classify(url: url, relative: relative, values: values, root: root)
      total += size
      sizes.append((relative, size))
      paths.append(relative)
    }
    guard total <= maxBytes else {
      let largest = sizes.sorted { $0.1 > $1.1 }.prefix(3)
        .map { "\($0.0) (\(ByteSize(bytes: $0.1)))" }
      throw ImageBuildError.contextTooLarge(bytes: total, limit: maxBytes, largest: Array(largest))
    }
    return Walked(paths: paths.sorted(), bytes: total)
  }

  /// Returns the entry's contribution to the context size, or throws for anything a tar member has
  /// no business being.
  private static func classify(
    url: URL, relative: String, values: URLResourceValues, root: URL
  ) throws -> UInt64 {
    func refuse(_ reason: String) -> ImageBuildError {
      ImageBuildError.contextUnsafeEntry(path: relative, reason: reason)
    }
    if values.isSymbolicLink == true {
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL
      let base = root.standardizedFileURL.path(percentEncoded: false)
      let inside = resolved.path(percentEncoded: false).hasPrefix(
        base.hasSuffix("/") ? base : base + "/")
      guard inside else { throw refuse("symbolic link resolves outside the build context") }
      return 0
    }
    guard values.isRegularFile == true else {
      throw refuse("only regular files, directories and in-context symlinks may be copied")
    }
    if let links = values.linkCount, links > 1 {
      throw refuse("hard link with \(links) references")
    }
    return UInt64(values.fileSize ?? 0)
  }

  /// `.producesRelativePathURLs` gives a `relativePath`, but a caller that passed an absolute
  /// `root` still sees absolute URLs on some paths; strip the prefix either way.
  private static func relativePath(of url: URL, under root: URL) -> String {
    if !url.relativePath.isEmpty, url.relativePath != url.path(percentEncoded: false) {
      return url.relativePath
    }
    let base = root.path(percentEncoded: false)
    let full = url.path(percentEncoded: false)
    guard full.hasPrefix(base) else { return url.lastPathComponent }
    return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}

/// SHA-256 over a file, streamed. `ImageStore` has an internal one; this module cannot see it and
/// only ever hashes recipe-sized inputs plus the context tar.
enum SHA256Digest {
  static func file(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return format(hasher.finalize())
  }

  static func bytes(_ data: Data) -> String {
    format(SHA256.hash(data: data))
  }

  private static func format(_ digest: SHA256.Digest) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}
