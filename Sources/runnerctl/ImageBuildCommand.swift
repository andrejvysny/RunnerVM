import ArgumentParser
import DaemonAPI
import Foundation
import ImageBuild
import RunnerCore

/// `runnerctl image build` (Phase 6 CLI). Talks to `image.build`/`build.*`; the actual builder
/// lives entirely in `runnerd` (`Sources/Orchestration/Build/*`).
extension Image {
  struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "build",
      abstract: "Build an image in-daemon from a Runnerfile-style recipe.",
      discussion: """
        <dir-or-Runnerfile> may name a recipe file directly or a directory containing one named \
        "Runnerfile" (default: the current directory). runnerd reads the recipe and its build \
        context itself, so both must be readable by whatever user runs it -- this command warns \
        when the invoking user differs from the daemon socket's owner.

        With --wait (the default) runnerctl tails the build's log to stdout, renders step \
        progress to stderr on a terminal, and prints the finished image's `image inspect` table \
        once the build succeeds. See docs/image-build.md for the instruction set, lifecycle and \
        the shipped recipes.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Recipe file, or a directory containing one. Default: the current directory.")
    var path: String = "."

    @Option(name: .long, help: "Local name to alias the image under once the build succeeds.")
    var name: String?

    @Option(
      name: .customLong("arg"),
      help: ArgumentHelp(
        "KEY=VALUE build argument; may be given more than once.",
        discussion: "Build arguments are NOT secrets: every value is stored in the build record, "
          + "written into the image's provenance metadata and pushed inside the OCI config of "
          + "`--push`. Never pass tokens, passwords or keys here."))
    var args: [String] = []

    @Option(name: .long, help: "Build context directory. Default: the recipe's own directory.")
    var context: String?

    @Option(name: .long, help: "Push the finished image to this registry reference.")
    var push: String?

    @Option(name: .long, help: "Builder VM vCPU count.")
    var cpus: Int?

    @Option(name: .long, help: "Builder VM memory, e.g. 4GiB.")
    var memory: String?

    @Option(name: .long, help: "Builder VM disk size, e.g. 16GiB.")
    var disk: String?

    @Option(name: .long, help: "Overall build timeout, e.g. 60m.")
    var timeout: String?

    @Flag(name: .long, help: "Ignore a previous build's cached base image and layers.")
    var noCache = false

    @Flag(
      inversion: .prefixedNo,
      help: "Wait for the build to finish. --no-wait returns the build id immediately.")
    var wait = true

    func validate() throws {
      for pair in args where !pair.contains("=") {
        throw ValidationError("--arg must be KEY=VALUE (got '\(pair)')")
      }
      // The daemon refuses these too (`BUILD_ARG_LOOKS_LIKE_SECRET`); failing here saves the
      // round trip and keeps the value out of the daemon's request log.
      if let key = BuildArgumentPolicy.firstSecretLookingArgument(in: Self.parseArgs(args)) {
        throw ValidationError(
          "BUILD_ARG_LOOKS_LIKE_SECRET: --arg \(key) looks like a credential. Build arguments "
            + "are recorded in the build row, the image provenance and any pushed OCI config; "
            + "they are not secrets. Remove it (see docs/image-build.md, \"Build arguments are "
            + "not secrets\").")
      }
    }

    func run() async throws {
      let recipePath = Build.recipePath(for: path)
      try Build.preflight(recipePath: recipePath, socketURL: options.socketURL)
      let request = try ImageBuildRequest(
        recipePath: recipePath,
        contextPath: context.map(Image.absolute),
        name: name,
        args: Build.parseArgs(args),
        push: push,
        cpus: cpus,
        memoryBytes: memory.map { try ByteSize(parsing: $0).bytes },
        diskBytes: disk.map { try ByteSize(parsing: $0).bytes },
        timeoutMs: timeout.map { try DurationValue(parsing: $0).seconds * 1_000 },
        noCache: noCache)
      let response = try await options.withDaemon { try await $0.imageBuild(request) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human:
        print("build \(response.buildId) started (\(response.from), \(response.totalSteps) steps)")
      }
      // `--wait` writes the build log straight to the fd (unbuffered, so it interleaves live with
      // the guest's own output); flush stdio's own buffer first or this line arrives after it.
      fflush(stdout)
      guard wait else { return }
      try await Build.follow(options, buildId: response.buildId)
    }

    // MARK: - Recipe resolution

    /// A directory argument resolves to `<dir>/Runnerfile`; a file argument is used as given.
    static func recipePath(for argument: String) -> String {
      let absolute = Image.absolute(argument)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory),
            isDirectory.boolValue
      else { return absolute }
      return (absolute as NSString).appendingPathComponent(RecipeParser.defaultFileName)
    }

    static func parseArgs(_ pairs: [String]) -> [String: String] {
      Dictionary(
        pairs.map { pair -> (String, String) in
          guard let eq = pair.firstIndex(of: "=") else { return (pair, "") }
          return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Local pre-flight

    /// Cheap, local checks before ever calling the daemon: a missing or unparseable recipe fails
    /// in milliseconds here rather than as a round trip to `image.build`, which re-parses the same
    /// file authoritatively and is the source of truth for anything this pre-flight cannot see
    /// (declared-but-unresolvable ARGs, the build context, host capacity).
    static func preflight(recipePath: String, socketURL: URL) throws {
      guard access(recipePath, R_OK) == 0 else {
        throw ValidationError("cannot read \(recipePath): \(String(cString: strerror(errno)))")
      }
      let text: String
      do {
        text = try String(contentsOfFile: recipePath, encoding: .utf8)
      } catch {
        throw ValidationError("cannot read \(recipePath): \(error.localizedDescription)")
      }
      do {
        // The sha256 recorded here is never inspected; the daemon computes its own authoritative
        // one once it reads the file for real.
        _ = try RecipeParser.parse(text, path: recipePath, sha256: "")
      } catch let error as RecipeError {
        throw ValidationError(Build.message(path: recipePath, error: error))
      }
      warnIfOwnerMismatch(recipePath: recipePath, socketURL: socketURL)
    }

    /// Most `RecipeError` messages already lead with `<line>: ...`; prefixing the path turns that
    /// into the familiar `path:line: message` compiler-style format. The two whole-file cases
    /// (`empty`/`missingFrom`) already name the path in their own message.
    static func message(path: String, error: RecipeError) -> String {
      switch error {
      case .empty, .missingFrom:
        return error.message
      default:
        return "\(path):\(error.message)"
      }
    }

    /// `runnerd` reads the recipe (and its context) as whatever user owns its socket -- usually
    /// not the operator invoking `runnerctl`. This cannot be a hard failure (the daemon is the
    /// authority on whether the read actually succeeds), just a heads-up before a build that will
    /// otherwise fail deep inside `image.build` with a less obvious error.
    private static func warnIfOwnerMismatch(recipePath: String, socketURL: URL) {
      var info = stat()
      guard stat(socketURL.path(percentEncoded: false), &info) == 0, info.st_uid != getuid()
      else { return }
      writeError(
        "runnerctl: warning: runnerd's socket is owned by uid \(info.st_uid), but this shell is "
          + "uid \(getuid()); make sure uid \(info.st_uid) can read \(recipePath) and its build "
          + "context")
    }

    // MARK: - Wait

    /// One connection for the whole wait, mirroring `OperationWaiter`: poll `build.get` for
    /// progress and `build.log` for new output every 500 ms until the log reports `done`.
    private static func follow(_ options: GlobalOptions, buildId: String) async throws {
      let final = try await options.withDaemon { client in
        try await BuildFollower.run(client, buildId: buildId)
      }
      guard final.state == ImageBuildState.succeeded.rawValue else {
        let code = final.failureCode ?? "BUILD_\(final.state.uppercased())"
        let message = final.failureMessage ?? "build ended in state \(final.state)"
        writeError("runnerctl: \(code): \(message)")
        throw ExitCode(1)
      }
      guard let digest = final.imageDigest else {
        print("build \(final.buildId) succeeded")
        return
      }
      let image = try await options.withDaemon { try await $0.imageGet(ref: digest) }
      switch options.output {
      case .json: try JSONOut.print(image)
      case .human:
        print(Table.fields(Image.fields(image), indent: ""))
        if let pushOperationId = final.pushOperationId { print("push operation: \(pushOperationId)") }
      }
    }
  }
}

/// Split out of `Image.Build` so the polling loop is a plain, testable-shaped function rather than
/// buried in a `run()` body.
private enum BuildFollower {
  static let interval: Duration = .milliseconds(500)

  static func run(_ client: DaemonClient, buildId: String) async throws -> BuildInfoDTO {
    var offset: Int64 = 0
    while true {
      let info = try await client.buildGet(buildId: buildId)
      tick(info)
      let log = try await client.buildLog(buildId: buildId, offset: offset)
      if !log.data.isEmpty { FileHandle.standardOutput.write(Data(log.data.utf8)) }
      offset = log.nextOffset
      if log.done { break }
      try await Task.sleep(for: interval)
    }
    clear()
    // One last read: `log.done` only guarantees the log is fully drained, not that this loop's
    // last `build.get` already observed the terminal state it was drained for.
    return try await client.buildGet(buildId: buildId)
  }

  /// Only on a terminal, matching `OperationWaiter.tick`: a redirected `image build > log` must
  /// not collect step-progress carriage returns alongside the real build log on stdout.
  private static func tick(_ info: BuildInfoDTO) {
    guard isatty(STDERR_FILENO) == 1 else { return }
    let line = if let instruction = info.currentInstruction, info.totalSteps > 0 {
      "[\(info.currentStep)/\(info.totalSteps)] \(instruction)"
    } else {
      info.state
    }
    FileHandle.standardError.write(Data("\r\u{1B}[K\(line)".utf8))
  }

  private static func clear() {
    guard isatty(STDERR_FILENO) == 1 else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
  }
}
