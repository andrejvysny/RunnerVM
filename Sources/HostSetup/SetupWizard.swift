import Foundation
import RunnerCore

/// The interactive half of `runnerctl setup`: facts in, `SetupAnswers` out, nothing touched.
///
/// Returns `nil` when the operator declines the summary — a refusal is a normal outcome, not an
/// error, and the host must be exactly as it was.
public struct SetupWizard: Sendable {
  private let io: any SetupIO

  public init(io: any SetupIO) {
    self.io = io
  }

  /// Bounded so a wizard driven by a pipe, a script, or someone holding Enter cannot spin
  /// forever on a question it will never get a valid answer to.
  static let maxAttempts = 5

  /// The operator gave up, or gave the same invalid answer `maxAttempts` times. Not an error:
  /// either way nothing has been touched and there is nothing to report.
  private struct Abandoned: Error {}

  public func run(facts: SetupHostFacts) -> SetupAnswers? {
    do {
      return try collect(facts: facts)
    } catch {
      io.say("Nothing was changed.")
      return nil
    }
  }

  private func collect(facts: SetupHostFacts) throws -> SetupAnswers? {
    preamble(facts)
    let mode = askMode()
    let scope = try askScope()
    let runnerGroup = askRunnerGroup(scope)
    let token = askToken()
    let (linux, macOS) = askEnvironments()
    let macOSSource = macOS ? askMacOSSource() : SetupDefaults.macOSSource
    let prefix = SetupDefaults.profilePrefix(hostID6: facts.hostID6)

    var answers = SetupAnswers(
      mode: mode, scope: scope, runnerGroup: runnerGroup, token: token,
      linuxEnabled: linux, macOSEnabled: macOS, macOSSource: macOSSource,
      linuxConcurrency: 1, macOSConcurrency: 1,
      linuxProfileName: SetupDefaults.linuxProfileName(prefix: prefix),
      macOSProfileName: SetupDefaults.macOSProfileName(prefix: prefix))

    if linux {
      answers.linuxConcurrency = try askLinuxConcurrency(facts)
      answers.linuxProfileName = try askProfileName(
        "Linux profile name", default: answers.linuxProfileName)
    }
    if macOS {
      answers.macOSConcurrency = try askMacOSConcurrency()
      answers.macOSProfileName = try askProfileName(
        "macOS profile name", default: answers.macOSProfileName)
    }

    summarize(answers, facts: facts)
    guard io.confirm("Continue", default: true) else {
      io.say("Nothing was changed.")
      return nil
    }
    return answers
  }

  // MARK: - Preamble

  private func preamble(_ facts: SetupHostFacts) {
    io.heading("RunnerVM setup")
    io.say("host:    \(facts.model), \(facts.cpuCount) CPUs, "
      + "\(ByteSize(bytes: facts.memoryBytes)) RAM, "
      + "\(ByteSize(bytes: facts.freeDiskBytes)) free")
    io.say("macOS:   \(facts.macOSVersion)\(facts.isAppleSilicon ? " (Apple Silicon)" : "")")
    io.say("host id: \(facts.hostID6.isEmpty ? "unavailable" : facts.hostID6)")
    if let warning = facts.fileVault.warning {
      io.say("")
      io.say("note: \(warning)")
    }
    if facts.existingInstall.isPresent {
      io.say("")
      io.say("note: an existing install was found (\(facts.existingInstall.summary)). "
        + "setup is re-runnable and will reconfigure it in place.")
    }
  }

  // MARK: - Questions

  private func askMode() -> ServiceDeploymentMode {
    io.heading("Deployment")
    let choice = io.choose(
      "How should runnerd start?",
      options: [
        "LaunchDaemon — headless, starts at boot, no login session needed",
        "LaunchAgent — runs in a GUI session; needs autologin to survive a reboot",
      ],
      default: 0)
    return choice == 0 ? .daemon : .agent
  }

  private func askScope() throws -> SetupScope {
    io.heading("GitHub scope")
    let choice = io.choose(
      "Register runners against:", options: ["a repository", "an organization"], default: 0)
    if choice == 1 {
      return .organization(owner: try askNonEmpty("Organization login"))
    }
    let owner = try askNonEmpty("Repository owner")
    let repository = try askNonEmpty("Repository name")
    return .repository(owner: owner, repository: repository)
  }

  /// Repository scopes have no runner groups; asking would be a question with no correct answer.
  private func askRunnerGroup(_ scope: SetupScope) -> String {
    guard case .organization = scope else { return SetupDefaults.runnerGroup }
    return io.ask("Runner group", default: SetupDefaults.runnerGroup)
  }

  private func askToken() -> String {
    io.heading("Credential")
    io.say("A fine-grained PAT with Actions read/write on the scope above, or a classic PAT with")
    io.say("`repo` (repository scope) / `admin:org` (organization scope).")
    let token = io.askSecret("GitHub token")
    if token.isEmpty {
      io.say("")
      io.say("warning: no token given. The daemon will install and run, but it cannot register a")
      io.say("         runner until you supply one:  sudo runnerctl auth login --token-stdin")
    }
    return token
  }

  private func askEnvironments() -> (linux: Bool, macOS: Bool) {
    io.heading("Runner environments")
    let linux = io.confirm("Linux runners (ubuntu-24)?", default: true)
    io.say("macOS guests are provisioned locally from a Cirrus Tart base; that lands with the")
    io.say("managed-image service and is not usable on the day this host is installed.")
    let macOS = io.confirm("macOS runners?", default: false)
    if !linux, !macOS {
      io.say("")
      io.say("note: no environments selected; the host will be installed with no runner profiles.")
    }
    return (linux, macOS)
  }

  private func askMacOSSource() -> String {
    io.ask("macOS base image", default: SetupDefaults.macOSSource)
  }

  private func askLinuxConcurrency(_ facts: SetupHostFacts) throws -> Int {
    io.heading("Concurrency")
    let advice = SetupSizing.advice(facts: facts)
    let spec = SetupDefaults.linuxResources
    io.say("Per Linux runner: \(spec.cpuCount) vCPU, \(ByteSize(bytes: spec.memoryBytes)) RAM, "
      + "\(ByteSize(bytes: spec.diskBytes)) disk")
    io.say(advice.summary)
    if advice.fitsNone {
      io.say("warning: this host does not fit even one runner of that shape after reserves; "
        + "the limiting factor is \(advice.limitingFactor).")
    }
    return try askCount("Concurrent Linux runners", default: advice.recommended, maximum: nil)
  }

  private func askMacOSConcurrency() throws -> Int {
    io.say("macOS is capped at \(SetupDefaults.macOSMaxConcurrency) concurrent guests per host "
      + "(Apple's licence allowance).")
    return try askCount(
      "Concurrent macOS runners", default: 1, maximum: SetupDefaults.macOSMaxConcurrency)
  }

  private func askProfileName(_ prompt: String, default defaultValue: String) throws -> String {
    try retrying(prompt) {
      let name = io.ask(prompt, default: defaultValue)
      guard RunnerConfiguration.isValidProfileName(name) else {
        io.say("must match [a-z0-9][a-z0-9._-]* — it becomes the runs-on label and the "
          + "scale-set name")
        return nil
      }
      return name
    }
  }

  // MARK: - Prompt helpers

  private func askNonEmpty(_ prompt: String) throws -> String {
    try retrying(prompt) {
      let answer = io.ask(prompt, default: nil)
      guard !answer.isEmpty else {
        io.say("required")
        return nil
      }
      return answer
    }
  }

  private func askCount(_ prompt: String, default defaultValue: Int, maximum: Int?) throws -> Int {
    try retrying(prompt) {
      let answer = io.ask(prompt, default: "\(defaultValue)")
      guard let value = Int(answer), value >= 1 else {
        io.say("enter a whole number of at least 1")
        return nil
      }
      if let maximum, value > maximum {
        io.say("at most \(maximum) on this host")
        return nil
      }
      return value
    }
  }

  /// Re-asks until `attempt` yields a value, then gives up rather than looping forever.
  private func retrying<T>(_ prompt: String, _ attempt: () -> T?) throws -> T {
    for _ in 0..<Self.maxAttempts {
      if let value = attempt() { return value }
    }
    io.say("no usable answer for '\(prompt)' after \(Self.maxAttempts) attempts; aborting.")
    throw Abandoned()
  }

  // MARK: - Summary

  private func summarize(_ answers: SetupAnswers, facts: SetupHostFacts) {
    io.heading("Summary")
    var rows: [(String, String)] = [
      ("mode", answers.mode == .daemon ? "LaunchDaemon (headless)" : "LaunchAgent (GUI session)"),
      ("scope", answers.scope.description),
    ]
    if case .organization = answers.scope {
      rows.append(("runner group", answers.runnerGroup))
    }
    rows.append(("token", answers.token.isEmpty ? "not supplied (set it later)" : "supplied"))
    if answers.linuxEnabled {
      rows.append((
        "linux profile",
        "\(answers.linuxProfileName) x\(answers.linuxConcurrency) — \(SetupDefaults.linuxImage)"))
    }
    if answers.macOSEnabled {
      rows.append((
        "macos profile",
        "\(answers.macOSProfileName) x\(answers.macOSConcurrency) — \(answers.macOSSource)"))
      rows.append(("macos image", "\(answers.managedImageName) (provisioned locally, see below)"))
    }
    rows.append(("state", SetupDefaults.stateDir))
    rows.append(("host id", facts.hostID6.isEmpty ? "unavailable" : facts.hostID6))
    let width = rows.map(\.0.count).max() ?? 0
    for (label, value) in rows {
      io.say("  \((label + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0))  \(value)")
    }
    io.blank()
  }
}
