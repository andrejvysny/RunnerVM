import Foundation
import ProcessSpawn
import RunnerCore

/// What one external command produced. `stdout`/`stderr` are decoded as UTF-8 and never `nil`:
/// every command `HostSetup` runs is a text-producing system tool.
public struct CommandResult: Sendable, Hashable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  /// The wall-clock ceiling expired and the command's process group was killed. `exitCode` alone
  /// cannot say so -- a tool that handles `SIGTERM` still exits `0`.
  public var timedOut: Bool
  /// The calling task was cancelled and the command's process group was killed for that reason.
  public var cancelled: Bool

  public init(
    exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
    cancelled: Bool = false
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.cancelled = cancelled
  }

  public var isSuccess: Bool { exitCode == 0 }

  /// `stdout` with surrounding whitespace removed — what nearly every caller here wants.
  public var trimmedStdout: String {
    stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The most informative line for an error message: stderr if the tool wrote one, else stdout.
  public var failureDetail: String {
    let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return error.isEmpty ? trimmedStdout : error
  }

  public static let success = CommandResult(exitCode: 0)
}

/// The single seam every host mutation goes through. `HostSetup` never constructs a `Process`
/// outside `DefaultCommandRunner`, so a test can prove the exact `dscl`/`launchctl` sequence a
/// step would run without a root shell, and `--dry-run` can intercept the same calls.
public protocol CommandRunner: Sendable {
  /// `timeout` is the wall clock this command gets before its process group is killed; `nil`
  /// means the runner's own default. Almost every caller wants that default -- the exceptions are
  /// the download and `installer` steps of an upgrade, which are bounded by a network and a
  /// package size rather than by a host tool's usual latency.
  func run(_ argv: [String], stdin: String?, timeout: Duration?) async throws -> CommandResult
}

extension CommandRunner {
  public func run(_ argv: [String], stdin: String? = nil) async throws -> CommandResult {
    try await run(argv, stdin: stdin, timeout: nil)
  }

  /// Runs `argv` and throws `SetupError.commandFailed` unless it exited zero.
  @discardableResult
  public func runChecked(
    _ argv: [String], stdin: String? = nil, timeout: Duration? = nil
  ) async throws -> CommandResult {
    let result = try await run(argv, stdin: stdin, timeout: timeout)
    // Cancellation first: an operator who pressed ctrl-C mid-`setup` gets a cancellation, not a
    // report that `installer` failed.
    guard !result.cancelled else { throw CancellationError() }
    guard result.isSuccess else {
      // A killed command's exit code names the signal that ended it, not what went wrong, so the
      // ceiling is what the message has to lead with.
      let detail = result.timedOut
        ? "timed out after \(DefaultCommandRunner.describe(timeout)) and was killed"
        : result.failureDetail
      throw SetupError.commandFailed(
        command: argv.joined(separator: " "), exitCode: result.exitCode, detail: detail)
    }
    return result
  }
}

/// Failures the setup layer raises itself, as opposed to the ones a daemon RPC returns.
public enum SetupError: RunnerError {
  case commandFailed(command: String, exitCode: Int32, detail: String)
  case executableMissing(String)
  case templateNotFound(name: String, searched: [String])
  case noFreeID(range: ClosedRange<Int>, kind: String)
  case socketNeverAppeared(path: String, seconds: Int)

  public var code: String {
    switch self {
    case .commandFailed: "SETUP_COMMAND_FAILED"
    case .executableMissing: "SETUP_EXECUTABLE_MISSING"
    case .templateNotFound: "SETUP_TEMPLATE_NOT_FOUND"
    case .noFreeID: "SETUP_NO_FREE_ID"
    case .socketNeverAppeared: "SETUP_SOCKET_NEVER_APPEARED"
    }
  }

  public var message: String {
    switch self {
    case let .commandFailed(command, exitCode, detail):
      "`\(command)` exited \(exitCode)" + (detail.isEmpty ? "" : ": \(detail)")
    case let .executableMissing(path):
      "\(path) is not present on this host"
    case let .templateNotFound(name, searched):
      "launchd template '\(name)' not found; searched \(searched.joined(separator: ", "))"
    case let .noFreeID(range, kind):
      "no free \(kind) in \(range.lowerBound)-\(range.upperBound)"
    case let .socketNeverAppeared(path, seconds):
      "\(path) did not appear within \(seconds)s; check the daemon's stdio log"
    }
  }

  public var retryable: Bool { false }
}

/// `ProcessSpawn`. Every process this module starts goes through here (`SmokeTest`'s `ps` scan
/// included).
///
/// A leaf `posix_spawn` target rather than `Foundation.Process` because `HostSetup` must never
/// import `Orchestration` (it is a client of the daemon, not part of it) and both need the same
/// guarantees: a bounded wall clock, `SIGTERM` then `SIGKILL` against the command's whole process
/// group, both pipes drained concurrently against a deadline, and a decoded exit code. `setup`
/// runs `launchctl`/`dscl`/`installer` as root; every one of those can wedge, and the previous
/// implementation read stdout to EOF before stderr and had no ceiling at all -- a `dscl` waiting
/// on the directory server hung `runnerctl setup` with no output.
///
/// Unlike the daemon's runner this passes the **whole** environment through. `runnerctl` is the
/// operator's own CLI, run from their shell: `curl` needs `http_proxy`/`HTTPS_PROXY`,
/// `CURL_CA_BUNDLE`, `SSL_CERT_FILE`; `installer` and `launchctl` read locale and `SUDO_*`.
/// Allowlisting here would break an upgrade behind a corporate proxy for no benefit -- there is no
/// trust boundary to defend, since the caller and the child are the same operator.
public struct DefaultCommandRunner: CommandRunner {
  /// Every host tool this module runs answers in well under a minute or is stuck.
  public static let defaultTimeout: Duration = .seconds(60)

  private let timeout: Duration
  private let killGrace: Duration
  private let drainGrace: Duration

  public init(
    timeout: Duration = defaultTimeout, killGrace: Duration = .seconds(10),
    drainGrace: Duration = .seconds(5)
  ) {
    self.timeout = timeout
    self.killGrace = killGrace
    self.drainGrace = drainGrace
  }

  public func run(_ argv: [String], stdin: String?, timeout: Duration?) async throws -> CommandResult {
    guard let executable = argv.first else {
      throw SetupError.executableMissing("<empty command>")
    }
    let request = SpawnRequest(
      executable: executable, arguments: Array(argv.dropFirst()),
      environment: ProcessInfo.processInfo.environment, standardInput: stdin,
      timeout: timeout ?? self.timeout, killGrace: killGrace, drainGrace: drainGrace)
    do {
      let result = try await ProcessSpawn.run(request)
      return CommandResult(
        exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
        timedOut: result.timedOut, cancelled: result.cancelled)
    } catch SpawnError.executableMissing, SpawnError.spawnFailed {
      throw SetupError.executableMissing(executable)
    } catch let error as SpawnError {
      // `pipeFailed` (EMFILE and friends) is this process failing to set the child up, not a
      // missing tool. Reported as a command failure so it reaches the operator through the same
      // `SETUP_COMMAND_FAILED` path every other step already handles, instead of escaping as a
      // module-foreign error nothing maps.
      throw SetupError.commandFailed(
        command: argv.joined(separator: " "), exitCode: -1, detail: "\(error)")
    }
  }

  /// The ceiling that applied, for a message. `nil` means the runner's default was used.
  static func describe(_ timeout: Duration?) -> String {
    "\(timeout ?? defaultTimeout)"
  }
}

/// `--dry-run`'s runner: read-only probes reach the host so the plan is computed against reality
/// (which uid is free, whether the account already exists), every mutation is recorded and
/// answered with success without running.
///
/// The alternative — a `dryRun` flag threaded through every step — makes each step responsible for
/// remembering not to touch the host. Intercepting at the one seam every mutation already goes
/// through makes that impossible to get wrong.
public actor PlanningCommandRunner: CommandRunner {
  private let underlying: any CommandRunner
  public private(set) var planned: [[String]] = []

  public init(underlying: any CommandRunner = DefaultCommandRunner()) {
    self.underlying = underlying
  }

  public func run(_ argv: [String], stdin: String?, timeout: Duration?) async throws -> CommandResult {
    guard Self.isReadOnly(argv) else {
      planned.append(argv)
      return .success
    }
    return try await underlying.run(argv, stdin: stdin, timeout: timeout)
  }

  /// Every command whose whole job is to report. `dscl` is split on its verb: `-read`/`-list`
  /// answer questions, `-create`/`-delete` change the directory node.
  static func isReadOnly(_ argv: [String]) -> Bool {
    guard let executable = argv.first else { return false }
    switch (executable as NSString).lastPathComponent {
    case "sysctl", "ioreg", "sw_vers", "id", "stat":
      return true
    case "fdesetup":
      return argv.contains("status")
    case "plutil":
      return argv.contains("-lint")
    case "launchctl":
      return argv.contains("print")
    case "dscl":
      return argv.contains("-read") || argv.contains("-list")
    default:
      return false
    }
  }
}

/// Scripted `CommandRunner` for tests: records every command in order and answers from a list of
/// stubs, so a step's exact command sequence is the assertion.
public actor RecordingCommandRunner: CommandRunner {
  /// Matches a command when every token in `tokens` appears somewhere in its argv, as a
  /// substring of any element — so `["sw_vers"]` matches `/usr/bin/sw_vers -productVersion`.
  /// Deliberately loose: tests assert on the recorded sequence, and a stub only has to be
  /// specific enough to pick the right answer.
  public struct Stub: Sendable {
    public var tokens: [String]
    public var result: CommandResult
    /// Consumed on its first match, so a later stub with the same tokens answers the next call.
    /// The one case that needs it is a command run twice with identical argv and two different
    /// truths -- the schema query an upgrade makes before and after the swap.
    public var once: Bool

    public init(_ tokens: [String], _ result: CommandResult, once: Bool = false) {
      self.tokens = tokens
      self.result = result
      self.once = once
    }

    public static func stdout(_ tokens: [String], _ text: String) -> Stub {
      Stub(tokens, CommandResult(exitCode: 0, stdout: text))
    }

    public static func once(_ tokens: [String], _ text: String) -> Stub {
      Stub(tokens, CommandResult(exitCode: 0, stdout: text), once: true)
    }

    public static func failure(_ tokens: [String], _ exitCode: Int32 = 1, _ detail: String = "") -> Stub {
      Stub(tokens, CommandResult(exitCode: exitCode, stderr: detail))
    }
  }

  private var stubs: [Stub]
  private let fallback: CommandResult
  public private(set) var commands: [[String]] = []

  public init(stubs: [Stub] = [], fallback: CommandResult = .success) {
    self.stubs = stubs
    self.fallback = fallback
  }

  public func run(
    _ argv: [String], stdin _: String?, timeout _: Duration?
  ) async throws -> CommandResult {
    commands.append(argv)
    guard let index = stubs.firstIndex(where: { stub in
      stub.tokens.allSatisfy { token in argv.contains { $0.contains(token) } }
    }) else { return fallback }
    let stub = stubs[index]
    if stub.once { stubs.remove(at: index) }
    return stub.result
  }

  /// The recorded commands as single strings, for readable expectations.
  public var lines: [String] { commands.map { $0.joined(separator: " ") } }

  /// Clears the recording, so a second phase of the same scenario — a rollback after an upgrade —
  /// can assert on its own sequence rather than on everything since the start.
  public func reset() { commands.removeAll() }

  public func add(_ stub: Stub) { stubs.insert(stub, at: 0) }
}
