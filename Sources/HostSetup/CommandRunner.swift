import Foundation
import RunnerCore

/// What one external command produced. `stdout`/`stderr` are decoded as UTF-8 and never `nil`:
/// every command `HostSetup` runs is a text-producing system tool.
public struct CommandResult: Sendable, Hashable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String

  public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
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
  func run(_ argv: [String], stdin: String?) async throws -> CommandResult
}

extension CommandRunner {
  public func run(_ argv: [String]) async throws -> CommandResult {
    try await run(argv, stdin: nil)
  }

  /// Runs `argv` and throws `SetupError.commandFailed` unless it exited zero.
  @discardableResult
  public func runChecked(_ argv: [String], stdin: String? = nil) async throws -> CommandResult {
    let result = try await run(argv, stdin: stdin)
    guard result.isSuccess else {
      throw SetupError.commandFailed(
        command: argv.joined(separator: " "), exitCode: result.exitCode,
        detail: result.failureDetail)
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

/// Foundation `Process`. The only place in this module that spawns anything.
public struct DefaultCommandRunner: CommandRunner {
  public init() {}

  /// The whole spawn/drain/wait sequence is blocking, so it runs on a GCD thread: parking a
  /// cooperative-pool thread per subprocess starves every other task in the process (measured
  /// 2026-08-28 on CI's 3-thread pool).
  public func run(_ argv: [String], stdin: String?) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try Self.blockingRun(argv, stdin: stdin) })
      }
    }
  }

  private static func blockingRun(_ argv: [String], stdin: String?) throws -> CommandResult {
    guard let executable = argv.first else {
      throw SetupError.executableMissing("<empty command>")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(argv.dropFirst())
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let input = Pipe()
    process.standardInput = input
    do {
      try process.run()
    } catch {
      throw SetupError.executableMissing(executable)
    }
    if let stdin {
      input.fileHandleForWriting.write(Data(stdin.utf8))
    }
    try? input.fileHandleForWriting.close()
    // Read before waiting: a command that fills a 64 KiB pipe buffer would otherwise deadlock.
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(
      exitCode: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self))
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

  public func run(_ argv: [String], stdin: String?) async throws -> CommandResult {
    guard Self.isReadOnly(argv) else {
      planned.append(argv)
      return .success
    }
    return try await underlying.run(argv, stdin: stdin)
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

  public func run(_ argv: [String], stdin _: String?) async throws -> CommandResult {
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
