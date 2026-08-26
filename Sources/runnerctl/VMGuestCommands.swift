import ArgumentParser
import DaemonAPI
import Foundation
import GuestControl

extension VM {
  struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "exec",
      abstract: "Run a command inside the guest and stream its output.",
      discussion: """
        Everything after `--` is the guest command line, passed to the agent verbatim (no shell). \
        stdout and stderr are forwarded as they arrive and runnerctl exits with the guest's exit \
        code. Example: runnerctl vm exec 3f2504e0 -- uname -a
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    @Option(name: .long, help: "Seconds the guest command may run before the agent kills it.")
    var timeout: Int = 30

    @Option(name: .long, help: "Maximum bytes of output the agent may return.")
    var maxOutput: Int = 1 << 20

    @Option(name: .long, help: "Working directory inside the guest.")
    var cwd: String?

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments, after `--`.")
    var command: [String] = []

    func run() async throws {
      // `.captureForPassthrough` keeps the `--` terminator; the guest must not see it as argv[0].
      let argv = command.first == "--" ? Array(command.dropFirst()) : command
      guard !argv.isEmpty else {
        throw ValidationError("no command given; use `runnerctl vm exec <id> -- <cmd> [args…]`")
      }
      let request = InstanceExecRequest(
        id: id, argv: argv, cwd: cwd, timeoutMs: Int64(timeout) * 1_000,
        maxOutputBytes: Int64(maxOutput))
      let code = try await options.withDaemon { client in
        try await Exec.forward(try client.instanceExec(request))
      }
      guard code == 0 else { throw ExitCode(code) }
    }

    /// Writes each chunk out as it lands rather than buffering: a long-running guest command has
    /// to look alive on the operator's terminal.
    private static func forward(
      _ events: AsyncThrowingStream<InstanceExecEvent, any Error>
    ) async throws -> Int32 {
      var exitCode: Int32 = 0
      for try await event in events {
        switch event {
        case .chunk(let chunk):
          let handle = chunk.stream == "stderr"
            ? FileHandle.standardError : FileHandle.standardOutput
          handle.write(chunk.data)
        case .exited(let code):
          exitCode = code
        }
      }
      return exitCode
    }
  }

  struct Metrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "metrics",
      abstract: "Show guest telemetry, plus what the host observes about the worker process.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    func run() async throws {
      let response = try await options.withDaemon { try await $0.instanceMetrics(id: id) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Metrics.render(response))
      }
    }

    static func render(_ response: InstanceMetricsResponse) -> String {
      let guest = response.guest
      var blocks = [
        "Guest\n" + Table.fields([
          ("collected", response.collectedAt),
          ("uptime", Format.duration(seconds: guest.uptimeSec)),
          ("cpu", String(
            format: "%.1f%% of %d cores  load %.2f %.2f %.2f", guest.cpu.usagePercent,
            guest.cpu.logicalCount, guest.cpu.load1, guest.cpu.load5, guest.cpu.load15)),
          ("memory", "\(Format.bytes(UInt64(max(0, guest.memory.usedBytes)))) used of "
            + "\(Format.bytes(UInt64(max(0, guest.memory.totalBytes))))"),
          ("root disk", "\(Format.bytes(UInt64(max(0, guest.disk.rootUsedBytes)))) used of "
            + "\(Format.bytes(UInt64(max(0, guest.disk.rootTotalBytes))))"),
          ("runner", Metrics.runnerLine(guest.runner)),
        ]),
      ]
      if let worker = response.worker {
        blocks.append("Worker\n" + Table.fields([
          ("pid", "\(worker.pid)"),
          ("rss", Format.bytes(worker.rssBytes)),
          ("cpu time", String(format: "%.1fs", worker.cpuSeconds)),
        ]))
      }
      if let warnings = guest.warnings, !warnings.isEmpty {
        blocks.append("Warnings\n" + warnings.map { "  \($0)" }.joined(separator: "\n"))
      }
      return blocks.joined(separator: "\n\n")
    }

    private static func runnerLine(_ runner: GuestMetrics.RunnerMetrics) -> String {
      guard runner.processRunning else { return "not running" }
      return String(
        format: "pid %d  %.1f%% cpu  %@", runner.pid ?? 0, runner.cpuPercent,
        Format.bytes(UInt64(max(0, runner.rssBytes))))
    }
  }

  struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "ssh",
      abstract: "Print the ssh command for an instance, or open the session with --connect.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    @Flag(name: .long, help: "Replace runnerctl with an interactive ssh session.")
    var connect = false

    func run() async throws {
      let info = try await options.withDaemon { try await $0.instanceSSHInfo(id: id) }
      guard info.sshEnabled else {
        writeError("runnerctl: SSH_DISABLED: ssh is disabled for this instance's profile")
        throw ExitCode(1)
      }
      guard let address = info.ipAddresses.first, let command = info.command else {
        writeError("runnerctl: GUEST_ADDRESS_UNKNOWN: the guest has reported no IP address")
        throw ExitCode(1)
      }
      guard connect else {
        switch options.output {
        case .json: try JSONOut.print(info)
        case .human: print(command)
        }
        return
      }
      SSH.replaceProcess(user: info.user, address: address)
    }

    /// `execv` rather than a child process: the operator gets a real tty on the guest, and
    /// runnerctl's exit status is ssh's own.
    private static func replaceProcess(user: String, address: String) -> Never {
      let path = "/usr/bin/ssh"
      let words = [path, "\(user)@\(address)"]
      var arguments = words.map { UnsafeMutablePointer<CChar>?(strdup($0)) }
      arguments.append(nil)
      _ = arguments.withUnsafeMutableBufferPointer { execv(path, $0.baseAddress!) }
      writeError("runnerctl: SSH_EXEC_FAILED: \(path): \(String(cString: strerror(errno)))")
      Foundation.exit(1)
    }
  }
}
