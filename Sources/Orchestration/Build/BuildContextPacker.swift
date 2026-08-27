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

    let list = staging.appending(path: "files.list")
    try writeNulDelimitedList(entries.paths, to: list)
    let tarball = payload.appending(path: tarName)
    try await runner.runChecked(tar, [
      "-cf", tarball.path(percentEncoded: false),
      "-C", root.path(percentEncoded: false),
      "--null",
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

  /// Writes `entries` as `entry\0entry\0…`, matched by `tar`'s `--null` on the `-T` read side.
  ///
  /// A newline-joined list (the previous format) hands bsdtar's `-T` reader two footguns: a line
  /// reading exactly `-C` changes tar's working directory for every entry after it (verified: a
  /// file merely *named* `-C` redirects subsequent lookups into whatever directory follows it on
  /// the next line -- `man tar` calls this out, and it reproduces against the host's bsdtar 3.5.3),
  /// and a name containing "\n" is split into two bogus entries. `--null` disables both: verified
  /// on this host that a NUL-delimited entry equal to `-C`, one starting with `-`, and one
  /// containing "\n" are each archived literally as a single member with that exact name (see
  /// `BuildContextPackerTests`) -- no `./` prefix is needed to defeat the `-C` special case.
  private static func writeNulDelimitedList(_ entries: [String], to url: URL) throws {
    var bytes = Data()
    for entry in entries {
      bytes.append(contentsOf: entry.utf8)
      bytes.append(0)
    }
    try bytes.write(to: url)
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
      let relative = try Self.relativePath(of: url, under: root)
      guard !relative.isEmpty else { continue }
      try Self.validateListable(relative)
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

  /// Refuses two byte patterns the NUL-delimited list can't carry. A NUL inside a path is
  /// impossible on any POSIX filesystem (the kernel uses it as the C-string terminator), but the
  /// list format's own delimiter depends on that holding, so it is checked rather than assumed. An
  /// empty component (e.g. from a doubled or trailing `/`) can't come out of the enumerator either,
  /// but would collide the entry with its own parent directory's name if it ever did.
  private static func validateListable(_ relative: String) throws {
    guard !relative.utf8.contains(0) else {
      throw ImageBuildError.contextUnsafeEntry(path: relative, reason: "name contains a NUL byte")
    }
    let hasEmptyComponent = relative.split(separator: "/", omittingEmptySubsequences: false)
      .contains { $0.isEmpty }
    guard !hasEmptyComponent else {
      throw ImageBuildError.contextUnsafeEntry(path: relative, reason: "name has an empty path component")
    }
  }

  /// `.producesRelativePathURLs` gives a `relativePath`, but a caller that passed an absolute
  /// `root` still sees absolute URLs on some paths; strip the prefix either way.
  ///
  /// Foundation versions disagree about what `path` returns for a relative URL (older ones give
  /// the absolute path, newer ones only the relative part), so the decision keys on `baseURL`
  /// rather than on comparing the two strings. Anything that still does not sit under the root
  /// is refused instead of being flattened to its file name, which would silently collapse
  /// nested `COPY` sources.
  private static func relativePath(of url: URL, under root: URL) throws -> String {
    let slashes = CharacterSet(charactersIn: "/")
    if url.baseURL != nil {
      let relative = url.relativePath.trimmingCharacters(in: slashes)
      if !relative.isEmpty { return relative }
    }
    let base = root.standardizedFileURL.path(percentEncoded: false)
      .trimmingCharacters(in: slashes)
    let full = url.absoluteURL.standardizedFileURL.path(percentEncoded: false)
      .trimmingCharacters(in: slashes)
    guard full == base || full.hasPrefix(base + "/") else {
      throw ImageBuildError.contextUnsafeEntry(
        path: full, reason: "resolves outside the build context \(base)")
    }
    return String(full.dropFirst(base.count)).trimmingCharacters(in: slashes)
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
