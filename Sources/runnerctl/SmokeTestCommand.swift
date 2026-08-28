import ArgumentParser
import DaemonAPI
import Foundation
import HostSetup
import RunnerCore

extension System {
  struct SmokeTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "smoke-test",
      abstract: "Boot a pinned instance of a profile and prove the guest actually works.",
      discussion: """
        Creates a --pinned maintenance instance, waits for cold boot, execs a guest command, and \
        (macOS only) runs the guest self-test and proves ssh is closed -- then deletes the \
        instance and checks nothing was left behind. Exits 1 if any check failed, 3 if the \
        daemon is unreachable.
        """)

    @OptionGroup var options: GlobalOptions

    @Option(
      name: .long,
      help: "Profile to smoke-test. Required unless exactly one profile is enabled.")
    var profile: String?

    @Option(name: .long, help: "Boot this image reference instead of the profile's.")
    var image: String?

    @Option(
      name: .long,
      help: ArgumentHelp(
        "How long the instance may live before the daemon deletes it (10s...24h).",
        discussion: "Duration syntax, e.g. 90s, 15m, 1h30m. Defaults to 15m."))
    var ttl: String?

    @Option(
      name: .long,
      help: ArgumentHelp(
        "How long to wait for the clone to reach idle before failing.",
        discussion: "Duration syntax, e.g. 90s, 4m. Defaults to 4m."))
    var timeout: String?

    @Option(name: .long, help: "RunnerVM state root (used for the leak checks).")
    var stateDir: String?

    @Option(name: .long, help: "Directory holding runnerd.sock and worker sockets.")
    var socketDir: String?

    func run() async throws {
      let ttlMs = try SmokeTestCommand.parseTTL(ttl)
      let bootTimeout = try SmokeTestCommand.parseTimeout(timeout)
      let paths = RunnerPaths.resolveRoots(stateDir: stateDir, socketDir: socketDir)
      let report = try await options.withDaemon { client -> SmokeTestReport in
        let profileName = try await SmokeTestCommand.resolveProfile(profile, client: client)
        let summary = try await client.profileGet(name: profileName)
        let smokeTest = SmokeTest(client: client, paths: paths)
        return await smokeTest.run(
          SmokeTestOptions(
            profile: profileName, imageOverride: image, ttlMs: ttlMs, bootTimeout: bootTimeout,
            macOS: summary.guestOS == GuestOS.macos.rawValue))
      }
      switch options.output {
      case .json: try JSONOut.print(report)
      case .human: print(SmokeTestCommand.render(report))
      }
      guard report.passed else { throw ExitCode(1) }
    }

    /// Mirrors `VM.Create.ttlMilliseconds`'s parsing, minus the `--pinned` gate: a smoke test is
    /// always pinned, so there is no bare `--ttl` to reject.
    static func resolveProfile(_ explicit: String?, client: DaemonClient) async throws -> String {
      if let explicit { return explicit }
      let enabled = try await client.profileList().profiles.filter(\.enabled)
      guard enabled.count == 1 else {
        throw ValidationError(
          "--profile is required (\(enabled.count) enabled profile(s); name one explicitly)")
      }
      return enabled[0].name
    }

    static func parseTTL(_ text: String?) throws -> Int64 {
      guard let text else { return MaintenanceTTL.defaultMs }
      guard let value = try? DurationValue(parsing: text) else {
        throw ValidationError("invalid --ttl '\(text)'; use a duration such as 15m or 1h30m")
      }
      return value.milliseconds
    }

    static func parseTimeout(_ text: String?) throws -> Duration {
      guard let text else { return .seconds(240) }
      guard let value = try? DurationValue(parsing: text) else {
        throw ValidationError("invalid --timeout '\(text)'; use a duration such as 120s or 4m")
      }
      return .milliseconds(value.milliseconds)
    }

    static func render(_ report: SmokeTestReport) -> String {
      var lines = ["profile: \(report.profile)"]
      if let instanceId = report.instanceId { lines.append("instance: \(instanceId)") }
      lines.append(Table.render(
        headers: ["", "CHECK", "DETAIL"],
        rows: report.checks.map { [$0.ok ? "✓" : "✗", $0.name, Format.optional($0.detail)] }))
      lines.append(report.passed ? "PASSED" : "FAILED")
      return lines.joined(separator: "\n")
    }
  }
}
