import ArgumentParser
import DaemonAPI
import Foundation
import RunnerCore

/// `runnerctl image update check|run|status` -- the operator surface over `images.updates`
/// (phase D6). Every subcommand answers with the same track table, so `check` and `run` show the
/// outcome in the shape `status` would have reported anyway.
struct ImageUpdate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Inspect and drive automatic image updates.",
    discussion: """
      A track is either a registry tag an enabled profile names (`kind: registryTag`) or an \
      images.managed[] entry (`kind: macosTart`). A profile pinned to an explicit @sha256: digest \
      is never tracked -- the operator already said which bytes they want.

      Nothing here can replace a working image: a candidate that fails to download, fails \
      qualification, or fails its boot-to-idle smoke test leaves the promoted digest exactly \
      where it was, and records why in the track's error.
      """,
    subcommands: [Check.self, Run.self, Status.self])

  @OptionGroup var options: GlobalOptions
}

extension ImageUpdate {
  struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "check",
      abstract: "Re-resolve every tracked source against its registry. Transfers nothing.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Check only this track. Default: every track.")
    var managed: String?

    func run() async throws {
      let response = try await options.withDaemon { try await $0.imageUpdateCheck(managed: managed) }
      try ImageUpdate.emit(response, options: options)
    }
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Resolve, pull, qualify and promote whatever has moved.",
      discussion: """
        The daemon starts the cycle and answers immediately -- a whole image does not fit inside \
        the socket's idle timeout. --wait (the default) then polls image.update.status until \
        every track is back to idle or failed, and exits non-zero if any of them failed.
        """)

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Update only this track. Default: every track.")
    var managed: String?

    @Flag(
      inversion: .prefixedNo,
      help: "Poll until the cycle finishes. --no-wait returns as soon as it is started.")
    var wait = true

    @Option(
      name: .long,
      help: "Seconds --wait may poll for before giving up and printing the tracks as they stand.")
    var timeout: Int = 3_600

    func run() async throws {
      let seconds = timeout
      let response = try await options.withDaemon { client -> ImageUpdateStatusResponse in
        let started = try await client.imageUpdateRun(managed: managed)
        guard wait else { return started }
        return try await ImageUpdate.poll(client, managed: managed, timeout: .seconds(seconds))
      }
      try ImageUpdate.emit(response, options: options)
      guard wait, response.tracks.contains(where: { $0.state == "failed" }) else { return }
      throw ExitCode(1)
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status", abstract: "Show every tracked image source.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.imageUpdateStatus() }
      try ImageUpdate.emit(response, options: options)
    }
  }

  /// Polls until every track this run touched is settled. `idle` and `failed` are the only two
  /// resting states `ManagedImageState` has; everything else means a pass still owns the row.
  ///
  /// `image.update.run` claims its tracks before answering, so the first poll already sees them
  /// running and cannot mistake "not started yet" for "finished". The deadline exists for the
  /// other direction: a daemon that dies mid-pull must not leave the CLI spinning forever.
  static func poll(
    _ client: DaemonClient, managed: String?, timeout: Duration,
    interval: Duration = .milliseconds(500)
  ) async throws -> ImageUpdateStatusResponse {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      let response = try await client.imageUpdateStatus()
      let watched = response.tracks.filter { managed == nil || $0.name == managed }
      if watched.allSatisfy({ $0.state == "idle" || $0.state == "failed" })
        || ContinuousClock.now >= deadline {
        return ImageUpdateStatusResponse(tracks: watched)
      }
      try await Task.sleep(for: interval)
    }
  }

  static func emit(_ response: ImageUpdateStatusResponse, options: GlobalOptions) throws {
    switch options.output {
    case .json: try JSONOut.print(response)
    case .human: print(table(response.tracks))
    }
  }

  static func table(_ tracks: [ImageUpdateTrackDTO]) -> String {
    let rendered = Table.render(
      headers: ["NAME", "KIND", "STATE", "CURRENT", "CHECKED", "UPDATED", "AUTO"],
      rows: tracks.map {
        [
          $0.name, $0.kind, $0.state, Format.optional($0.currentImageDigest.map(Format.shortDigest)),
          ago($0.lastCheckedAt), ago($0.lastUpdatedAt), Format.yesNo($0.autoUpdate),
        ]
      })
    // Errors get their own lines rather than a column: a qualification failure is a sentence, and
    // truncating it into a table cell is exactly the case where an operator needs the whole text.
    let errors = tracks.compactMap { track in
      track.lastError.map { "  \(track.name): \($0)" }
    }
    guard !errors.isEmpty else { return rendered }
    return rendered + "\n\n" + errors.joined(separator: "\n")
  }

  /// Relative time, like the `AGE` columns elsewhere: "when was this last looked at" is the
  /// question, and an absolute RFC-3339 instant makes the reader do the subtraction.
  static func ago(_ timestamp: String?) -> String {
    guard let timestamp, let date = RFC3339.date(from: timestamp) else { return "-" }
    return Format.duration(seconds: Int64(max(0, Date().timeIntervalSince(date)))) + " ago"
  }
}
