import ArgumentParser
import ConfigLoader
import Foundation
import Logging
import Orchestration
import RunnerCore
import RunnerLogging

@main
struct RunnerD: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runnerd",
    abstract: "RunnerVM host daemon.",
    discussion: """
      M1 runs the daemon in the foreground only: it takes the single-daemon lock, migrates SQLite, \
      applies a configuration file, serves the daemon API on runnerd.sock and reconciles on a timer.
      """
  )

  @Flag(name: .long, help: "Run in the foreground as the current user. Required in M1.")
  var foreground = false

  @Option(name: .long, help: "Configuration file to validate and apply at startup.")
  var config: String?

  @Option(
    name: .long,
    help: "Root directory for RunnerVM state; state/, images/, instances/ and logs/ live under it.")
  var stateDir: String?

  @Option(name: .long, help: "Directory holding runnerd.sock. Keep it short: sun_path is 104 bytes.")
  var socketDir: String?

  @Option(
    name: .long,
    help: "trace, debug, info, notice, warning, error or critical. Falls back to RUNNERVM_LOG_LEVEL, then info."
  )
  var logLevel: String?

  @Option(name: .long, help: "Seconds between reconcile ticks.")
  var reconcileInterval: Int = 10

  @Option(
    name: .long,
    help: """
      Also write the JSON log to this file, rotating in process. Defaults to \
      <state-dir>/logs/runnerd/runnerd.log whenever stderr is not a terminal; "off" disables it.
      """
  )
  var logFile: String?

  /// Flag wins over the environment, which wins over the built-in default (spec §42 forward
  /// compatibility with the launchd plists' `RUNNERVM_LOG_LEVEL`).
  private var effectiveLogLevel: String {
    logLevel ?? ProcessInfo.processInfo.environment["RUNNERVM_LOG_LEVEL"] ?? "info"
  }

  func validate() throws {
    guard foreground else {
      throw ValidationError("only --foreground is supported in M1")
    }
    guard Logger.Level(rawValue: effectiveLogLevel) != nil else {
      throw ValidationError("unknown --log-level '\(effectiveLogLevel)'")
    }
    guard reconcileInterval > 0 else {
      throw ValidationError("--reconcile-interval must be positive")
    }
  }

  func run() async throws {
    let paths = resolvedPaths()
    let fileSink = openLogFile(paths: paths, logging: pendingLoggingConfig())
    LoggingSystemBootstrap.bootstrapJSON(
      minimumLevel: Logger.Level(rawValue: effectiveLogLevel) ?? .info,
      sink: fileSink.map { LoggingSystemBootstrap.tee([JSONLogHandler.defaultSink, $0.sink()]) }
        ?? JSONLogHandler.defaultSink)
    let logger = Logger(component: .daemon)
    if let fileSink {
      logger.info(
        "daemon log file",
        metadata: ["path": .string(fileSink.url.path(percentEncoded: false))])
    }
    let runtime = DaemonRuntime(
      options: DaemonRuntime.Options(
        paths: paths,
        configPath: config.map { URL(fileURLWithPath: $0) },
        reconcileInterval: .seconds(reconcileInterval),
        // Only this user's tools may drive the daemon (spec §66; getpeereid check in RPCServer).
        allowedUIDs: [getuid()]),
      parseConfig: { try ConfigLoader.load(yaml: $0) },
      logger: logger)

    do {
      try await runtime.start()
    } catch {
      logger.critical("startup failed", metadata: ["error": .string(describe(error))])
      throw ExitCode.failure
    }

    let stop = StopSignal()
    let sources = installSignalHandlers { await stop.fire() }
    await stop.wait()
    withExtendedLifetime(sources) {}
    await runtime.stop()
  }

  /// stderr always keeps the log — launchd captures it, and an operator running this in a terminal
  /// reads it there. The file is additional, and only where it earns its place: under launchd
  /// stderr is already a file nothing rotates in process, while an interactive run would just
  /// litter the state directory. `isatty` is the only honest signal for that distinction, because
  /// `--foreground` is mandatory in this build and the launchd plists pass it too.
  private func openLogFile(paths: RunnerPaths, logging: LoggingConfig) -> RotatingFileSink? {
    if logFile == "off" { return nil }
    let explicit = logFile.map { URL(fileURLWithPath: $0) }
    guard logging.file.enabled || explicit != nil else { return nil }
    guard let url = explicit ?? (isatty(STDERR_FILENO) == 1 ? nil : paths.daemonLogFile) else {
      return nil
    }
    do {
      return try RotatingFileSink(
        url: url,
        options: RotatingFileSink.Options(
          maxSizeBytes: logging.file.maxSizeBytes, maxFiles: logging.file.maxFiles))
    } catch {
      FileHandle.standardError.write(Data("runnerd: \(error)\n".utf8))
      return nil
    }
  }

  /// Logging has to be up before anything can report a configuration error, so `--config` is
  /// peeked at here rather than waited for. A document that does not parse simply yields the
  /// defaults; `DaemonRuntime` re-parses it for real moments later and reports the failure
  /// properly.
  private func pendingLoggingConfig() -> LoggingConfig {
    guard let config,
          let yaml = try? String(contentsOf: URL(fileURLWithPath: config), encoding: .utf8),
          let parsed = try? ConfigLoader.load(yaml: yaml)
    else { return LoggingConfig() }
    return parsed.logging
  }

  private func resolvedPaths() -> RunnerPaths {
    let development = RunnerPaths.development(
      uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser)
    return RunnerPaths(
      rootDir: stateDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? development.rootDir,
      runtimeDir: socketDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? development.runtimeDir)
  }

  private func describe(_ error: any Error) -> String {
    (error as? any RunnerError).map { "\($0.code): \($0.message)" } ?? String(describing: error)
  }

  /// `DispatchSource` only sees a signal that the default disposition ignores, so SIG_IGN comes
  /// first. The returned sources must stay alive for the handlers to keep firing.
  private func installSignalHandlers(
    _ onSignal: @escaping @Sendable () async -> Void
  ) -> [any DispatchSourceSignal] {
    let queue = DispatchQueue(label: "com.runnervm.runnerd.signals")
    return [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
      source.setEventHandler { Task { await onSignal() } }
      source.resume()
      return source
    }
  }
}

/// One-shot shutdown latch: the signal handler fires it, `run` waits on it.
actor StopSignal {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fire() {
    guard !fired else { return }
    fired = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    guard !fired else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
