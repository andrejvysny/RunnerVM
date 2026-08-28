import ArgumentParser
import DaemonAPI
import Foundation
import RunnerCore

struct RunnerCtl: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runnerctl",
    abstract: "Control and inspect the RunnerVM daemon.",
    discussion: """
      runnerctl talks to runnerd over runnerd.sock and never opens SQLite, instance files or \
      GitHub directly. Use --output json for automation; the JSON fields are more stable than \
      the human tables.

      The socket is discovered automatically: --socket, then RUNNERVM_SOCKET, then the production \
      socket (/var/run/runnervm/runnerd.sock) when it exists, then the development one.
      """,
    version: "runnerctl \(RunnerVMVersion.current)",
    subcommands: [
      Status.self, Version.self, ConfigCommand.self, Profile.self, Scope.self, Image.self,
      Registry.self, VM.self, Auth.self, GitHubCommand.self, Runner.self, ScaleSet.self,
      Debug.self, Doctor.self, System.self, MetricsCommand.self, BuildCommand.self,
      SetupCommand.self, UpgradeCommand.self,
    ]
  )

  @OptionGroup var options: GlobalOptions
}

extension GlobalOptions {
  /// `--socket` > `RUNNERVM_SOCKET` > the production socket if a daemon laid one down > the
  /// development socket. See `RunnerPaths.resolveSocket`.
  var socketURL: URL { RunnerPaths.resolveSocket(explicit: socket) }

  /// One connection per invocation, closed before the command returns.
  func withDaemon<T>(_ body: (DaemonClient) async throws -> T) async throws -> T {
    let client = try await DaemonClient.connect(socketPath: socketURL)
    do {
      let value = try await body(client)
      await client.close()
      return value
    } catch {
      await client.close()
      throw error
    }
  }
}

/// Exit codes: 0 ok, 1 daemon error, 2 usage, 3 daemon unreachable.
@main
enum RunnerCtlMain {
  static func main() async {
    var command: any ParsableCommand
    do {
      command = try RunnerCtl.parseAsRoot()
    } catch {
      exitAfterParsing(error)
    }
    do {
      if var runnable = command as? any AsyncParsableCommand {
        try await runnable.run()
      } else {
        try command.run()
      }
    } catch {
      exitAfterRunning(error)
    }
    exit(0)
  }

  /// A parse failure is always a usage problem; `--help` surfaces as a "clean exit".
  private static func exitAfterParsing(_ error: any Error) -> Never {
    exitForArgumentParser(error, fallback: 2)
  }

  /// ArgumentParser answers `--help` by returning a command whose `run()` throws, so the
  /// help/usage handling has to sit on this path as well.
  private static func exitAfterRunning(_ error: any Error) -> Never {
    switch error {
    case let code as ExitCode:
      exit(code.rawValue)
    case let daemon as DaemonClientError:
      writeError("runnerctl: \(daemon.code): \(daemon.message)")
      if daemon.isUnreachable {
        writeError("hint: start the daemon with `runnerd --foreground`")
        exit(3)
      }
      exit(1)
    case let runner as any RunnerError:
      writeError("runnerctl: \(runner.code): \(runner.message)")
      exit(1)
    default:
      // Anything left is either the help request or a genuinely unexpected failure.
      exitForArgumentParser(error, fallback: 1)
    }
  }

  private static func exitForArgumentParser(_ error: any Error, fallback: Int32) -> Never {
    let message = RunnerCtl.fullMessage(for: error)
    if RunnerCtl.exitCode(for: error) == .success {
      print(message)
      exit(0)
    }
    writeError(message)
    exit(fallback)
  }
}
