import ArgumentParser
import DaemonAPI
import Foundation

/// Host maintenance (spec §108, §109). Aliased to `daemon` because that is the name the design
/// document uses for the same commands.
struct System: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "system",
    abstract: "Put the host into maintenance, or stop the daemon.",
    subcommands: [Drain.self, Resume.self, Offline.self, Shutdown.self],
    aliases: ["daemon"])
}

extension System {
  struct Drain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "drain",
      abstract: "Advertise zero capacity and admit no new jobs; running jobs finish.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Block until the last active job finishes.")
    var wait = false

    @Option(name: .long, help: "Seconds to wait with --wait.")
    var timeout: Int = 900

    func run() async throws {
      let response = try await options.withDaemon {
        try await $0.systemDrain(wait: wait, timeoutMs: Int64(max(0, timeout)) * 1_000)
      }
      try System.report(response, options: options, verb: "draining")
      if wait, !response.drained { throw ExitCode(1) }
    }
  }

  struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "resume", abstract: "Return the host to normal and start advertising again.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.systemResume() }
      try System.report(response, options: options, verb: "normal")
    }
  }

  struct Offline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "offline", abstract: "Drain, then park the host offline for maintenance.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.systemOffline() }
      try System.report(response, options: options, verb: "offline")
    }
  }

  struct Shutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "shutdown", abstract: "Drain and stop runnerd. VMs keep running.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Stop even while jobs are still running.")
    var force = false

    @Option(name: .long, help: "Seconds to wait for jobs to finish without --force.")
    var timeout: Int = 900

    /// The daemon answers before it closes the socket, so a clean reply here means the shutdown
    /// was accepted, not that the process is already gone.
    func run() async throws {
      let response = try await options.withDaemon {
        try await $0.systemShutdown(force: force, timeoutMs: Int64(max(0, timeout)) * 1_000)
      }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print("runnerd is shutting down (mode \(response.mode))")
      }
    }
  }

  static func report(
    _ response: SystemModeResponse, options: GlobalOptions, verb: String
  ) throws {
    switch options.output {
    case .json:
      try JSONOut.print(response)
    case .human:
      let jobs = response.activeSessions == 1 ? "1 active job" : "\(response.activeSessions) active jobs"
      print("host is \(verb) (\(jobs))")
    }
  }
}
