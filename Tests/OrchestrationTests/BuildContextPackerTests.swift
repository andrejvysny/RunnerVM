import Foundation
import ImageBuild
import RunnerCore
import Testing

@testable import Orchestration

/// Adversarial coverage for `BuildContextPacker`'s tar invocation: every case here inspects the
/// packed `context.tar` (its raw bytes, `tar -tf`, or a real `tar -x` into a fresh directory)
/// rather than trusting a zero exit code. Uses the real `SystemProcessRunner` -- this is
/// macOS-only code, and only the genuine `/usr/bin/tar` proves what actually lands in the archive.
///
/// Roots live under a SHORT `/tmp/rvmctx-XXXX`, not the package's own (much longer) temp
/// directory: the Unix-socket case binds `AF_UNIX`, and `sun_path` only holds 104 bytes.
@Suite
struct BuildContextPackerTests {

  // MARK: - Fixture helpers

  private func makeShortRoot() throws -> URL {
    let root = URL(
      fileURLWithPath: "/tmp/rvmctx-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Builds `root/relative` treating `relative` as a raw path string (it may itself contain `/`
  /// for nested directories) rather than a single path component, so a fixture name may contain
  /// any byte a POSIX filename allows -- including the ones this suite exists to exercise.
  private func join(_ root: URL, _ relative: String) -> URL {
    URL(fileURLWithPath: root.path(percentEncoded: false) + "/" + relative)
  }

  private func writeFile(_ root: URL, _ relative: String, _ contents: String) throws {
    let url = join(root, relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  /// Packs `context` with the real tools, returning the tar and file-list paths the test needs to
  /// inspect (both live under `staging`, which the caller controls precisely so it can find them).
  /// `destination` must NOT sit inside `staging`: `pack()` builds the ISO at
  /// `staging/context.iso` itself before moving it out, so a destination reusing that same path
  /// would have the packer delete its own freshly-built file out from under itself.
  private func pack(
    context: URL, ignore: RecipeIgnore = .parse(""), staging: URL,
    maxBytes: UInt64 = 8 << 20, runner: any ProcessRunner = SystemProcessRunner()
  ) async throws -> (packed: PackedContext, tar: URL, filesList: URL) {
    let suffix = UUID().uuidString.prefix(8)
    let destination = staging.deletingLastPathComponent().appending(path: "context-\(suffix).img")
    let packed = try await BuildContextPacker.pack(
      context: context, ignore: ignore, into: destination, maxBytes: maxBytes, staging: staging,
      runner: runner)
    return (
      packed, staging.appending(path: "payload").appending(path: BuildContextPacker.tarName),
      staging.appending(path: "files.list")
    )
  }

  // MARK: - Extraction

  private struct ExtractedEntry {
    var relativePath: String
    var isDirectory: Bool
    var isSymlink: Bool
    var linkTarget: String?
    var contents: Data?
  }

  /// Runs the real `tar -x` into a fresh directory, then walks the result. Every entry's own
  /// ancestor chain is re-resolved with `resolvingSymlinksInPath()` (a `realpath(3)` equivalent)
  /// and checked against the extraction root's OWN resolved form -- a plain string-prefix compare
  /// would pass trivially (macOS `/tmp` is itself a symlink to `/private/tmp`), so this is the
  /// check that would actually catch a `-C` mixup or any other path the archive escaped through.
  private func extract(_ tar: URL, into extractionRoot: URL) async throws -> [ExtractedEntry] {
    try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
    let result = try await SystemProcessRunner().run(
      "/usr/bin/tar",
      ["-xf", tar.path(percentEncoded: false), "-C", extractionRoot.path(percentEncoded: false)],
      timeout: .seconds(30))
    #expect(result.exitCode == 0, "tar -x failed: \(result.stderr)")
    return try inspect(extractionRoot)
  }

  private func inspect(_ extractionRoot: URL) throws -> [ExtractedEntry] {
    let canonicalRoot = extractionRoot.resolvingSymlinksInPath().standardizedFileURL
      .path(percentEncoded: false)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let walker = FileManager.default.enumerator(
      at: extractionRoot, includingPropertiesForKeys: Array(keys),
      options: [.producesRelativePathURLs]
    ) else { return [] }

    var entries: [ExtractedEntry] = []
    for case let url as URL in walker {
      let relative = url.relativePath
      guard !relative.isEmpty else { continue }
      // `.producesRelativePathURLs` URLs answer `path`/`deletingLastPathComponent` differently
      // across Foundation versions (macOS 15 gives the relative part, macOS 26 the absolute
      // path); every filesystem call below goes through the absolute form so the CI toolchain
      // and the dev host see the same file.
      let absolute = url.absoluteURL.standardizedFileURL
      let values = try url.resourceValues(forKeys: keys)
      let isSymlink = values.isSymbolicLink == true
      let isDirectory = values.isDirectory == true
      assertContained(
        absolute, relative: relative, isSymlink: isSymlink, isDirectory: isDirectory,
        canonicalRoot: canonicalRoot)
      entries.append(ExtractedEntry(
        relativePath: relative, isDirectory: isDirectory, isSymlink: isSymlink,
        linkTarget: isSymlink
          ? try? FileManager.default.destinationOfSymbolicLink(atPath: Self.plainPath(absolute))
          : nil,
        contents: (!isDirectory && !isSymlink) ? try? Data(contentsOf: absolute) : nil))
    }
    return entries
  }

  /// Resolves everything except a symlink's own final component (following that would resolve
  /// through to wherever the link points, which is not the question here) and asserts it stayed
  /// under the canonical extraction root.
  /// A symlink to a directory is enumerated with a trailing slash, and `readlink` on `link/`
  /// resolves through the link instead of reading it.
  private static func plainPath(_ url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  private func assertContained(
    _ absolute: URL, relative: String, isSymlink: Bool, isDirectory: Bool, canonicalRoot: String
  ) {
    let ancestor = (isSymlink || !isDirectory) ? absolute.deletingLastPathComponent() : absolute
    let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    #expect(
      resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/"),
      "escaped the extraction root: \(relative) resolved under \(resolved)")
  }

  private func listMembers(_ tar: URL) async throws -> ProcessResult {
    try await SystemProcessRunner().run(
      "/usr/bin/tar", ["-tf", tar.path(percentEncoded: false)], timeout: .seconds(30))
  }

  // MARK: - Refusal helper

  /// Runs `pack()` expecting `BUILD_CONTEXT_UNSAFE_ENTRY`, and confirms nothing was written at
  /// all: `walk()`/`classify()` throw before `pack()` ever creates `staging`, so a genuine refusal
  /// leaves no tar, no ISO, no partial output for a later step to accidentally trust.
  private func expectRefused(context: URL, staging: URL) async throws {
    let destination = staging.deletingLastPathComponent().appending(path: "refused.img")
    let error = await #expect(throws: ImageBuildError.self) {
      _ = try await BuildContextPacker.pack(
        context: context, ignore: .parse(""), into: destination,
        maxBytes: 8 << 20, staging: staging, runner: SystemProcessRunner())
    }
    #expect(error?.code == "BUILD_CONTEXT_UNSAFE_ENTRY")
    #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
  }

  // MARK: - Positive: names tar's own option parsing would otherwise choke on

  @Test func adversarialNamesArePackedAndExtractedVerbatim() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    var fixtures: [(relative: String, contents: String)] = [
      ("normal.txt", "normal"),
      ("name-with\nnewline.txt", "hasNewline"),
      ("name-with\rcarriage.txt", "hasCR"),
      ("name-with\ttab.txt", "hasTab"),
      ("name with spaces.txt", "hasSpaces"),
      ("-leadingdash.txt", "hasLeadingDash"),
      ("-C", "literalDashC"),
      ("--no-recursion", "literalNoRecursion"),
      ("..x/inner.txt", "dotDotXDir"),
      ("...", "tripleDot"),
    ]
    // 200 levels deep, short component names so the whole path stays well under PATH_MAX (1024).
    let deepPath = (0..<200).map(String.init).joined(separator: "/") + "/bottom.txt"
    fixtures.append((deepPath, "deepContent"))
    for (relative, contents) in fixtures { try writeFile(root, relative, contents) }

    let staging = root.appending(path: "staging")
    let (_, tar, _) = try await pack(context: root, staging: staging)

    let extractionRoot = root.appending(path: "extracted")
    let extracted = try await extract(tar, into: extractionRoot)
    let files = extracted.filter { !$0.isDirectory }

    #expect(Set(files.map(\.relativePath)) == Set(fixtures.map(\.relative)))
    for (relative, contents) in fixtures {
      let match = files.first { $0.relativePath == relative }
      #expect(match?.contents == Data(contents.utf8), "content mismatch for \(relative)")
    }

    // `tar -tf` is the other half of "inspect the archive, not the exit code": every name free of
    // control characters must appear verbatim in its listing. `\n` obviously can't survive a
    // newline-per-line stdout format; bsdtar's `-t` (unlike `-c`/`-x`, both verified elsewhere in
    // this test to be byte-exact) additionally *escapes* `\r` and `\t` to literal two-character
    // `\r`/`\t` for display, so those two are excluded from this specific check too.
    let listing = try await listMembers(tar)
    #expect(listing.exitCode == 0)
    let controlCharacters = CharacterSet(charactersIn: "\n\r\t")
    for (relative, _) in fixtures where relative.rangeOfCharacter(from: controlCharacters) == nil {
      #expect(listing.stdout.contains(relative), "tar -tf did not list \(relative)")
    }
  }

  // MARK: - Positive: symlinks

  @Test func symlinkChainAndDirectorySymlinkAreKeptAsSymlinkMembers() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root, "target.txt", "chained")
    try FileManager.default.createSymbolicLink(
      atPath: join(root, "link-b").path(percentEncoded: false), withDestinationPath: "target.txt")
    try FileManager.default.createSymbolicLink(
      atPath: join(root, "link-a").path(percentEncoded: false), withDestinationPath: "link-b")
    try FileManager.default.createDirectory(at: join(root, "realdir"), withIntermediateDirectories: true)
    try writeFile(root, "realdir/inside.txt", "insideDir")
    try FileManager.default.createSymbolicLink(
      atPath: join(root, "link-to-dir").path(percentEncoded: false), withDestinationPath: "realdir")

    let staging = root.appending(path: "staging")
    let (_, tar, _) = try await pack(context: root, staging: staging)
    let extracted = try await extract(tar, into: root.appending(path: "extracted"))

    let linkA = try #require(extracted.first { $0.relativePath == "link-a" })
    #expect(linkA.isSymlink)
    #expect(linkA.linkTarget == "link-b")
    let linkB = try #require(extracted.first { $0.relativePath == "link-b" })
    #expect(linkB.isSymlink)
    #expect(linkB.linkTarget == "target.txt")
    let linkToDir = try #require(extracted.first { $0.relativePath == "link-to-dir" })
    #expect(linkToDir.isSymlink, "a symlink to a directory must be kept as a symlink, not followed")
    #expect(linkToDir.linkTarget == "realdir")
  }

  @Test func anAbsoluteSymlinkTargetInsideTheContextIsKept() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root, "real.txt", "absoluteInsideTarget")
    let absoluteTarget = join(root, "real.txt").path(percentEncoded: false)
    try FileManager.default.createSymbolicLink(
      atPath: join(root, "abs-link").path(percentEncoded: false), withDestinationPath: absoluteTarget)

    let staging = root.appending(path: "staging")
    let (_, tar, _) = try await pack(context: root, staging: staging)
    let extracted = try await extract(tar, into: root.appending(path: "extracted"))

    let link = try #require(extracted.first { $0.relativePath == "abs-link" })
    #expect(link.isSymlink)
    #expect(link.linkTarget == absoluteTarget)
  }

  @Test func aSymlinkEscapingTheContextIsRefused() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suffix = UUID().uuidString.prefix(6)
    let secret = root.deletingLastPathComponent().appending(path: "outside-\(suffix).txt")
    try Data("secret".utf8).write(to: secret)
    defer { try? FileManager.default.removeItem(at: secret) }
    try FileManager.default.createSymbolicLink(
      atPath: join(root, "escape").path(percentEncoded: false),
      withDestinationPath: secret.path(percentEncoded: false))

    try await expectRefused(context: root, staging: root.appending(path: "staging"))
  }

  // MARK: - Refusals: nothing a tar member has business being

  @Test func aHardLinkIsRefused() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root, "original.txt", "shared")
    try FileManager.default.linkItem(
      at: join(root, "original.txt"), to: join(root, "hardlinked.txt"))

    try await expectRefused(context: root, staging: root.appending(path: "staging"))
  }

  @Test func aFIFOIsRefused() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fifoPath = join(root, "a-fifo").path(percentEncoded: false)
    #expect(mkfifo(fifoPath, 0o600) == 0, "mkfifo failed: errno \(errno)")

    try await expectRefused(context: root, staging: root.appending(path: "staging"))
  }

  @Test func aUnixSocketIsRefused() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try bindUnixSocket(at: join(root, "a-socket").path(percentEncoded: false))

    try await expectRefused(context: root, staging: root.appending(path: "staging"))
  }

  /// `mknod` for a character device needs root. CI/dev users are unprivileged, so this records a
  /// known issue with the errno rather than silently reporting green when the case never ran.
  @Test func aDeviceNodeIsRefused() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let devicePath = join(root, "a-device").path(percentEncoded: false)
    guard mknod(devicePath, mode_t(S_IFCHR) | 0o600, 0) == 0 else {
      let failure = errno
      guard failure == EPERM else {
        Issue.record("mknod failed unexpectedly: errno \(failure)")
        return
      }
      withKnownIssue("mknod needs root; unavailable to this unprivileged test user") {
        Issue.record("device node case not exercised here: mknod failed with EPERM")
      }
      return
    }

    try await expectRefused(context: root, staging: root.appending(path: "staging"))
  }

  // MARK: - .runnerignore

  @Test func runnerignoreSkipsADirectoryContainingANewlineNamedFile() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root, "kept.txt", "kept")
    try writeFile(root, "skipped/inner\nname.txt", "shouldNeverBePacked")
    let ignore = RecipeIgnore.parse("skipped/\n")

    let staging = root.appending(path: "staging")
    let (_, tar, _) = try await pack(context: root, ignore: ignore, staging: staging)
    let extracted = try await extract(tar, into: root.appending(path: "extracted"))

    #expect(extracted.contains { $0.relativePath == "kept.txt" })
    #expect(!extracted.contains { $0.relativePath.hasPrefix("skipped") })
  }

  // MARK: - The list format itself

  @Test func theFileListIsNulDelimitedAndTarIsInvokedWithNull() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(root, "a.txt", "A")
    try writeFile(root, "b b.txt", "B")

    let staging = root.appending(path: "staging")
    let recorder = RecordingRealRunner()
    let (_, _, filesList) = try await pack(context: root, staging: staging, runner: recorder)

    let tarCall = try #require(await recorder.invocations.first { $0.executable.hasSuffix("tar") })
    #expect(tarCall.arguments.contains("--null"))
    #expect(tarCall.arguments.contains("-C"))
    #expect(tarCall.arguments.contains("--no-recursion"))

    let listBytes = try Data(contentsOf: filesList)
    #expect(listBytes == Data("a.txt\0b b.txt\0".utf8))
  }

  // MARK: - Unicode normalization (see BuildContextPacker.swift's `writeNulDelimitedList` doc)

  /// Two things this test had to work around, both verified empirically against this host and
  /// worth recording since they contradict the naive expectation of "both forms preserved":
  ///
  /// 1. An NFC-composed and an NFD-composed name that render the same are the SAME directory
  ///    entry on default (case-insensitive, normalization-insensitive) APFS -- writing both to one
  ///    directory silently overwrites, it does not create two files. Kept in separate directories
  ///    here to avoid that collision entirely.
  /// 2. `walk()`'s `relativePath(of:under:)` reads `URL.relativePath`, and Foundation normalizes
  ///    that string to NFD regardless of the on-disk byte form -- confirmed by writing an
  ///    NFC-composed file and reading back an NFD `relativePath` for it. This is a pre-existing
  ///    property of `walk()`, not something `--null`/NUL-delimiting touches, so both entries land
  ///    in `files.list` (and the archive) under the SAME NFD byte form for "café.txt", just under
  ///    different parent directories. `tar -t`/`tar -x` on macOS re-normalize to NFD too when
  ///    reading names back out of an archive, so this test reads the archive's raw bytes directly
  ///    instead of trusting either of those.
  @Test func unicodeNamedFilesPackWithoutCrashingOrCorruptingOtherEntries() async throws {
    let root = try makeShortRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let nfc = "caf\u{00E9}.txt"
    let nfd = "cafe\u{0301}.txt"
    try writeFile(root, "nfc-dir/\(nfc)", "NFC-CONTENT")
    try writeFile(root, "nfd-dir/\(nfd)", "NFD-CONTENT")

    let staging = root.appending(path: "staging")
    let (_, tar, filesList) = try await pack(context: root, staging: staging)

    let listBytes = try Data(contentsOf: filesList)
    let tarBytes = try Data(contentsOf: tar)
    for prefix in ["nfc-dir/", "nfd-dir/"] {
      let expected = Data("\(prefix)\(nfd)".utf8)
      #expect(listBytes.range(of: expected) != nil, "files.list missing \(prefix)\(nfd)")
      #expect(tarBytes.range(of: expected) != nil, "context.tar missing \(prefix)\(nfd)")
    }
  }
}

// MARK: - Seams

/// Binds (but does not listen on) a Unix-domain socket special file at `path`, matching how
/// `RunnerVM`'s own RPC listeners create one -- see `UnixSocketListener.bind(descriptor:to:)`.
private func bindUnixSocket(at path: String) throws {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(descriptor >= 0, "socket() failed: errno \(errno)")
  defer { close(descriptor) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(path.utf8)
  try #require(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path), "socket path too long")
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
    raw[pathBytes.count] = 0
  }
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      Foundation.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  #expect(result == 0, "bind() failed: errno \(errno)")
}

/// Wraps the real runner to capture argv while still executing for real: this suite needs both the
/// genuine `context.tar` on disk and the exact command line that produced it.
private actor RecordingRealRunner: ProcessRunner {
  struct Invocation: Sendable {
    var executable: String
    var arguments: [String]
  }

  private let inner = SystemProcessRunner()
  private(set) var invocations: [Invocation] = []

  func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ProcessResult {
    invocations.append(Invocation(executable: executable, arguments: arguments))
    return try await inner.run(executable, arguments, timeout: timeout)
  }
}
