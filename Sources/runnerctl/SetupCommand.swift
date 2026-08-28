import ArgumentParser
import DaemonAPI
import Foundation
import HostSetup
import RunnerCore

/// `runnerctl setup` — the interactive host provisioning entry point.
///
/// Everything it does lives in `HostSetup`; this type is the flag surface, the root check, and the
/// wiring of the real `CommandRunner`/`SetupIO`/`DaemonClient` into `HostInstaller`.
struct SetupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "setup",
    abstract: "Provision this Mac as a RunnerVM host.",
    discussion: """
      Creates the `_runnervm` service account, lays out the state directory, writes config.yaml, \
      installs and starts the launchd job, stores the GitHub token, pulls the Linux image, \
      applies the profiles and boots one VM to prove the host works.

      Re-runnable: an existing account, directory or plist is verified rather than recreated. \
      Requires root (use sudo) unless --dry-run, which prints the plan and the generated YAML \
      without touching anything.
      """)

  // No `GlobalOptions`: `setup` talks to the daemon it just installed, at the socket its own
  // --runtime-dir implies, and has no JSON output mode to select.

  @Option(name: .long, help: "daemon (headless, recommended) or agent (GUI session).")
  var mode: ServiceDeploymentMode = .daemon

  @Flag(name: .long, help: "Take every answer from flags; never prompt. Requires --scope.")
  var nonInteractive = false

  @Option(
    name: .long,
    help: ArgumentHelp(
      "org:<owner> or repo:<owner>/<repo>.",
      discussion: "Required with --non-interactive; prefills the wizard otherwise."))
  var scope: String?

  @Option(name: .long, help: "Runner group for an organization scope.")
  var runnerGroup: String = SetupDefaults.runnerGroup

  @Flag(name: .long, help: "Read the GitHub token from standard input.")
  var tokenStdin = false

  @Flag(
    inversion: .prefixedNo,
    help: "Create the Linux runner profile.")
  var linux = true

  @Flag(
    name: .long,
    help: ArgumentHelp(
      "Also provision a macOS runner profile.",
      discussion: "setup drives the managed build -> qualify -> promote run, sizes the profile "
        + "to the promoted image and activates it. Expect an hour or more; a failure leaves the "
        + "host Linux-ready with the macOS profile commented out."))
  var macos = false

  @Option(name: .long, help: "macOS base image to track.")
  var macosSource: String = SetupDefaults.macOSSource

  @Option(
    name: .long,
    help: "How long to wait for the macOS provisioning run. 120m, 3h, 7200s.")
  var macosTimeout: String = "120m"

  @Option(name: .long, help: "Concurrent Linux runners. Default: what the host's capacity allows.")
  var linuxConcurrency: Int?

  @Option(name: .long, help: "Concurrent macOS runners (at most 2).")
  var macosConcurrency: Int = 1

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Profile name prefix.",
      discussion: "Defaults to rvm-<host6>, derived from this Mac's IOPlatformUUID so two hosts "
        + "in one GitHub scope cannot claim the same scale-set session."))
  var profilePrefix: String?

  @Flag(name: .long, help: "Print the plan and the generated config; change nothing.")
  var dryRun = false

  @Option(name: .long, help: "Override the state directory.")
  var stateDir: String = SetupDefaults.stateDir

  @Option(name: .long, help: "Override the runtime (socket) directory.")
  var runtimeDir: String = SetupDefaults.runtimeDir

  func validate() throws {
    if let scope, SetupScope.parse(scope) == nil {
      throw ValidationError("--scope must be org:<owner> or repo:<owner>/<repo>")
    }
    if nonInteractive, scope == nil {
      throw ValidationError("--non-interactive requires --scope org:<owner> or repo:<owner>/<repo>")
    }
    if macosConcurrency < 1 || macosConcurrency > SetupDefaults.macOSMaxConcurrency {
      throw ValidationError(
        "--macos-concurrency must be between 1 and \(SetupDefaults.macOSMaxConcurrency)")
    }
    if let linuxConcurrency, linuxConcurrency < 1 {
      throw ValidationError("--linux-concurrency must be at least 1")
    }
    if let profilePrefix, !RunnerConfiguration.isValidProfileName(profilePrefix) {
      throw ValidationError("--profile-prefix must match [a-z0-9][a-z0-9._-]*")
    }
    guard (try? DurationValue(parsing: macosTimeout)) != nil else {
      throw ValidationError("--macos-timeout must be a duration like 120m, 3h or 7200s")
    }
    guard dryRun || geteuid() == 0 else {
      throw ValidationError(
        "setup writes to /Library and creates a service account, so it needs root: "
          + "re-run as `sudo runnerctl setup …`, or pass --dry-run to see the plan without "
          + "changing anything")
    }
  }

  func run() async throws {
    let io = TTYSetupIO()
    // Every mutation goes through this one seam, so --dry-run intercepts at exactly one place.
    let baseRunner = DefaultCommandRunner()
    let runner: any CommandRunner = dryRun
      ? PlanningCommandRunner(underlying: baseRunner) : baseRunner

    let facts = await HostPreflight(runner: baseRunner)
      .gather(stateDir: stateDir, configPath: "\(stateDir)/config.yaml")
    if !facts.isAppleSilicon {
      throw ValidationError(
        "RunnerVM needs an Apple Silicon Mac; this host reports \(facts.model)")
    }

    guard let answers = try resolveAnswers(facts: facts, io: io) else {
      throw ExitCode.success  // the operator declined at the summary; nothing was changed
    }

    let plan = SetupPlanner.plan(
      answers: answers, facts: facts, stateDir: stateDir, runtimeDir: runtimeDir)
    let timeout = (try? DurationValue(parsing: macosTimeout)) ?? .minutes(120)
    let installer = HostInstaller(
      dependencies(runner: runner, io: io), dryRun: dryRun, macOSTimeout: timeout.duration)
    let report = await installer.install(plan, token: answers.token)
    guard report.ok else { throw ExitCode(1) }
  }

  // MARK: - Answers

  /// `nil` means the operator declined the wizard's summary.
  private func resolveAnswers(facts: SetupHostFacts, io: any SetupIO) throws -> SetupAnswers? {
    let token = tokenStdin ? Self.readTokenFromStdin() : ""
    guard nonInteractive else {
      var answers = SetupWizard(io: io).run(facts: facts)
      // --token-stdin wins over the prompt: it is how an unattended `curl | bash` supplies one.
      if var resolved = answers, tokenStdin {
        resolved.token = token
        answers = resolved
      }
      return answers
    }
    guard let scope, let parsed = SetupScope.parse(scope) else {
      throw ValidationError("--non-interactive requires --scope")
    }
    let prefix = profilePrefix ?? SetupDefaults.profilePrefix(hostID6: facts.hostID6)
    return SetupAnswers(
      mode: mode,
      scope: parsed,
      runnerGroup: runnerGroup,
      token: token,
      linuxEnabled: linux,
      macOSEnabled: macos,
      macOSSource: macosSource,
      linuxConcurrency: linuxConcurrency ?? SetupSizing.advice(facts: facts).recommended,
      macOSConcurrency: macosConcurrency,
      linuxProfileName: SetupDefaults.linuxProfileName(prefix: prefix),
      macOSProfileName: SetupDefaults.macOSProfileName(prefix: prefix))
  }

  private static func readTokenFromStdin() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Wiring

  private func dependencies(
    runner: any CommandRunner, io: any SetupIO
  ) -> HostInstaller.Dependencies {
    HostInstaller.Dependencies(
      runner: runner,
      io: io,
      accounts: ServiceAccountManager(runner: runner),
      launchd: LaunchdManager(runner: runner),
      connect: { socketPath in
        try await DaemonClient.connect(socketPath: URL(fileURLWithPath: socketPath))
      })
  }
}

/// `--mode daemon|agent`. `ServiceDeploymentMode` lives in `HostSetup`, which must not depend on
/// ArgumentParser, so the conformance is added here at the CLI boundary.
extension ServiceDeploymentMode: ExpressibleByArgument {}
