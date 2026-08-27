import ArgumentParser
import DaemonAPI
import Foundation

struct Runner: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runner",
    abstract: "Inspect GitHub runner sessions.",
    discussion: """
      A runner session is the GitHub half of a job: JIT registration, secret delivery, the runner \
      going online, the job, and cleanup. It has its own lifecycle, deliberately separate from \
      the VM's.
      """,
    subcommands: [List.self, Show.self])

  @OptionGroup var options: GlobalOptions
}

extension Runner {
  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List runner sessions, newest first.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Only sessions that have not reached a terminal state.")
    var active = false

    func run() async throws {
      let response = try await options.withDaemon { try await $0.runnerList() }
      let sessions = active ? response.sessions.filter { !$0.terminal } : response.sessions
      switch options.output {
      case .json: try JSONOut.print(RunnerListResponse(sessions: sessions))
      case .human: print(Runner.table(sessions))
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Show one runner session with its timeline.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Runner session id.")
    var id: String

    func run() async throws {
      let session = try await options.withDaemon { try await $0.runnerGet(sessionId: id) }
      switch options.output {
      case .json: try JSONOut.print(session)
      case .human:
        print(Table.fields(Runner.fields(session), indent: ""))
        print("\ntimeline\n" + Runner.timeline(session))
      }
    }
  }

  static func table(_ sessions: [RunnerSessionDTO]) -> String {
    Table.render(
      headers: ["ID", "PROFILE", "INSTANCE", "STATE", "RUNNER", "RESULT", "CREATED"],
      rows: sessions.map {
        [
          String($0.id.prefix(8)), $0.profile, String($0.instanceId.prefix(8)), $0.state,
          $0.githubRunnerId.map(String.init) ?? "-", Format.optional($0.result ?? $0.failureCode),
          $0.createdAt,
        ]
      })
  }

  static func fields(_ session: RunnerSessionDTO) -> [(String, String)] {
    [
      ("id", session.id),
      ("instance", session.instanceId),
      ("profile", session.profile),
      ("jit source", session.jitSource),
      ("state", session.state),
      ("terminal", Format.yesNo(session.terminal)),
      ("github runner", session.githubRunnerId.map { "\($0)" } ?? "-"),
      ("runner name", Format.optional(session.githubRunnerName)),
      ("result", Format.optional(session.result)),
      ("failure", Format.optional(session.failureCode)),
    ]
  }

  /// The §48 sequence, in the order it happened, so a stuck session shows where it stopped.
  static func timeline(_ session: RunnerSessionDTO) -> String {
    Table.fields([
      ("created", session.createdAt),
      ("jit issued", Format.optional(session.jitIssuedAt)),
      ("jit delivered", Format.optional(session.jitDeliveredAt)),
      ("runner started", Format.optional(session.runnerStartedAt)),
      ("runner online", Format.optional(session.runnerOnlineAt)),
      ("job started", Format.optional(session.jobStartedAt)),
      ("job finished", Format.optional(session.jobFinishedAt)),
      ("updated", session.updatedAt),
    ])
  }
}

struct Debug: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "debug",
    abstract: "Exercise the runner path without waiting for GitHub demand.",
    subcommands: [RunJIT.self, Demand.self, ScaleSet.self])

  @OptionGroup var options: GlobalOptions
}

extension Debug {
  struct RunJIT: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run-jit",
      abstract: "Register one JIT runner on an idle VM of a profile (spec §148).",
      discussion: """
        Creates an instance if the profile has no idle one, then registers a runner labelled \
        `self-hosted,<profile>`. Whatever job GitHub routes to that label runs once; with --wait \
        the command polls until the session is terminal and prints its timeline.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Profile name.")
    var profile: String

    @Flag(name: .long, help: "Poll until the session reaches a terminal state.")
    var wait = false

    @Option(name: .long, help: "Seconds to wait for a terminal state with --wait.")
    var waitTimeout: Int = 900

    func run() async throws {
      let started = try await options.withDaemon { client -> DebugRunJITResponse in
        let response = try await client.debugRunJIT(profile: profile)
        guard wait else { return response }
        _ = try await RunJIT.poll(
          client: client, sessionId: response.sessionId, timeout: waitTimeout,
          quiet: options.output == .json)
        return response
      }
      guard wait else {
        report(started, session: nil)
        return
      }
      let session = try await options.withDaemon {
        try await $0.runnerGet(sessionId: started.sessionId)
      }
      report(started, session: session)
    }

    private func report(_ started: DebugRunJITResponse, session: RunnerSessionDTO?) {
      switch options.output {
      case .json:
        try? session.map { try JSONOut.print($0) } ?? JSONOut.print(started)
      case .human:
        print("session  \(started.sessionId)")
        print("instance \(started.instanceId)\(started.createdInstance ? " (created)" : "")")
        guard let session else { return }
        print("state    \(session.state)\(session.result.map { " (\($0))" } ?? "")")
        print("\ntimeline\n" + Runner.timeline(session))
      }
    }

    /// Polls `runner.get` rather than holding a streaming call open: a job can outlive any
    /// reasonable RPC deadline.
    static func poll(
      client: DaemonClient, sessionId: String, timeout: Int, quiet: Bool
    ) async throws -> RunnerSessionDTO {
      let deadline = Date().addingTimeInterval(Double(timeout))
      var lastState = ""
      while Date() < deadline {
        let session = try await client.runnerGet(sessionId: sessionId)
        if session.state != lastState, !quiet {
          writeError("… \(session.state)")
          lastState = session.state
        }
        if session.terminal { return session }
        try await Task.sleep(for: .seconds(2))
      }
      throw ValidationError(
        "session \(sessionId) did not finish within \(timeout)s; `runnerctl runner show` has its state")
    }
  }
}
