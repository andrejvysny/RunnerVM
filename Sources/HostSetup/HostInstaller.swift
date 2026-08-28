import DaemonAPI
import Foundation
import RunnerCore

/// Executes a `SetupPlan`.
///
/// Failure semantics follow `docs/design/distribution.md`, "Failure semantics": a GitHub auth
/// failure leaves the daemon installed and running but not schedulable and is reported rather than
/// rolled back, while anything that would leave the host half-built (the account, the directory
/// layout, the launchd job) aborts.
public struct HostInstaller: Sendable {
  /// Everything the installer needs from the outside world, so the whole thing is testable.
  public struct Dependencies: Sendable {
    public var runner: any CommandRunner
    public var io: any SetupIO
    public var accounts: ServiceAccountManager
    public var launchd: LaunchdManager
    /// Opens a connection once the socket exists.
    public var connect: @Sendable (String) async throws -> any SetupDaemon
    /// Writes text to a staging path and returns it; the privileged copy is a runner command.
    public var writeTemporary: @Sendable (String, String) throws -> String
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
      runner: any CommandRunner,
      io: any SetupIO,
      accounts: ServiceAccountManager,
      launchd: LaunchdManager,
      connect: @escaping @Sendable (String) async throws -> any SetupDaemon,
      writeTemporary: @escaping @Sendable (String, String) throws -> String
        = LaunchdManager.writeTemporaryFile,
      sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
      self.runner = runner
      self.io = io
      self.accounts = accounts
      self.launchd = launchd
      self.connect = connect
      self.writeTemporary = writeTemporary
      self.sleep = sleep
    }
  }

  static let install = "/usr/bin/install"
  static let mkdir = "/bin/mkdir"
  static let chown = "/usr/sbin/chown"
  static let chmod = "/bin/chmod"
  static let operationPollInterval = Duration.seconds(2)

  private let deps: Dependencies
  private let dryRun: Bool

  public init(_ deps: Dependencies, dryRun: Bool = false) {
    self.deps = deps
    self.dryRun = dryRun
  }

  // MARK: - Entry point

  public func install(_ plan: SetupPlan, token: String) async -> SetupReport {
    var report = SetupReport(dryRun: dryRun)
    let io = deps.io

    io.heading(dryRun ? "Plan (nothing will be changed)" : "Installing")

    guard await accountStep(plan, report: &report) else { return await finish(plan, report) }
    guard await directoryStep(plan, report: &report) else { return await finish(plan, report) }
    guard await configStep(plan, report: &report) else { return await finish(plan, report) }
    guard await launchdStep(plan, report: &report) else { return await finish(plan, report) }

    guard !dryRun else {
      io.say("(dry run: the daemon is not started, so nothing after this point runs)")
      return await finish(plan, report)
    }

    guard await socketStep(plan, report: &report), let daemon = await connect(plan, &report) else {
      return await finish(plan, report)
    }

    await authStep(daemon, token: token, report: &report)
    let pulled = await imagePullStep(daemon, plan: plan, report: &report)
    await configApplyStep(daemon, plan: plan, report: &report)
    await smokeTestStep(daemon, plan: plan, pulled: pulled, report: &report)
    return await finish(plan, report)
  }

  // MARK: - Host steps

  private func accountStep(_ plan: SetupPlan, report: inout SetupReport) async -> Bool {
    do {
      let account = try await deps.accounts.ensure(plan.account)
      report.record(SetupReport.Name.account, true, "\(plan.account.user): \(account.summary)")
      return true
    } catch {
      report.record(SetupReport.Name.account, false, describe(error))
      return false
    }
  }

  /// The `scripts/install.sh` section-6 layout, verbatim. `runnerd` creates most of these lazily
  /// too, but a fresh install lays them out up front so every one of them starts with the right
  /// owner instead of inheriting root's.
  private func directoryStep(_ plan: SetupPlan, report: inout SetupReport) async -> Bool {
    let state = plan.stateDir
    let owner = plan.account.ownership
    // (path, mode) — 0750 everywhere under the state root: nothing RunnerVM writes at runtime is
    // group- or world-readable.
    let directories: [(String, String)] = [
      (state, "0750"),
      ("\(state)/images", "0750"),
      ("\(state)/instances", "0750"),
      ("\(state)/logs", "0750"),
      ("\(state)/logs/instances", "0750"),
      ("\(state)/logs/builds", "0750"),
      ("\(state)/logs/runnerd", "0750"),
      ("\(state)/state", "0750"),
      ("\(state)/state/builds", "0750"),
      ("\(state)/cache", "0750"),
      ("\(state)/cache/base-images", "0750"),
      (plan.runtimeDir, "0700"),
    ]
    do {
      for (path, mode) in directories {
        try await deps.runner.runChecked([Self.mkdir, "-p", path])
        try await deps.runner.runChecked([Self.chmod, mode, path])
        try await deps.runner.runChecked([Self.chown, owner, path])
      }
      report.record(
        SetupReport.Name.directories, true, "\(directories.count) directories, \(owner)")
      return true
    } catch {
      report.record(SetupReport.Name.directories, false, describe(error))
      return false
    }
  }

  /// The bootstrap document, 0640 and owned by the service account: it is operator-editable, and
  /// it is the file `runnerd` reads at every start.
  private func configStep(_ plan: SetupPlan, report: inout SetupReport) async -> Bool {
    do {
      let staged = try deps.writeTemporary(plan.configWithoutProfiles, "config.yaml")
      try await deps.runner.runChecked([Self.install, "-m", "0640", staged, plan.configPath])
      try await deps.runner.runChecked([Self.chown, plan.account.ownership, plan.configPath])
      report.record(SetupReport.Name.config, true, plan.configPath)
      return true
    } catch {
      report.record(SetupReport.Name.config, false, describe(error))
      return false
    }
  }

  private func launchdStep(_ plan: SetupPlan, report: inout SetupReport) async -> Bool {
    let spec = LaunchdJobSpec(
      mode: plan.mode, configPath: plan.configPath, stateDir: plan.stateDir,
      runtimeDir: plan.runtimeDir, serviceUser: plan.account.user,
      serviceGroup: plan.account.group)
    do {
      let steps = try await deps.launchd.install(spec)
      report.record(SetupReport.Name.launchd, true, steps.joined(separator: ", "))
      return true
    } catch {
      report.record(SetupReport.Name.launchd, false, describe(error))
      return false
    }
  }

  private func socketStep(_ plan: SetupPlan, report: inout SetupReport) async -> Bool {
    do {
      let elapsed = try await deps.launchd.waitForSocket(at: plan.socketPath)
      report.record(
        SetupReport.Name.socket, true, "\(plan.socketPath) after \(elapsed.components.seconds)s")
      return true
    } catch {
      report.record(SetupReport.Name.socket, false, describe(error))
      deps.io.say("The daemon did not publish its socket. Its early output is in "
        + "\(plan.stateDir)/logs/runnerd/stdio.log")
      return false
    }
  }

  private func connect(_ plan: SetupPlan, _ report: inout SetupReport) async -> (any SetupDaemon)? {
    do {
      return try await deps.connect(plan.socketPath)
    } catch {
      report.record(SetupReport.Name.connect, false, describe(error))
      return nil
    }
  }

  // MARK: - Daemon steps

  /// An absent token is not a failure: the operator was told at the prompt that the host would be
  /// installed but not schedulable, and this records that state rather than inventing an error.
  private func authStep(
    _ daemon: any SetupDaemon, token: String, report: inout SetupReport
  ) async {
    guard !token.isEmpty else {
      report.record(
        SetupReport.Name.auth, true,
        "skipped; set one with `sudo runnerctl auth login --token-stdin`")
      return
    }
    do {
      let response = try await daemon.authLogin(token: token)
      report.record(SetupReport.Name.auth, true, response.location)
    } catch {
      report.record(SetupReport.Name.auth, false, describe(error))
      return
    }
    await githubTestStep(daemon, report: &report)
  }

  /// The daemon stays installed and running when this fails — it is simply not schedulable. The
  /// exact permission text is printed here because that is the one thing the operator has to fix.
  private func githubTestStep(_ daemon: any SetupDaemon, report: inout SetupReport) async {
    do {
      let response = try await daemon.githubTest()
      let broken = response.scopes.filter { !$0.schedulable }
      guard broken.isEmpty, response.auth.state == "healthy" else {
        let detail = broken.first?.problems.first.map { "\($0.code): \($0.detail)" }
          ?? response.auth.problem ?? "auth state \(response.auth.state)"
        report.record(SetupReport.Name.githubTest, false, detail)
        printPermissionGuidance(response)
        return
      }
      let login = response.auth.login.map { " as \($0)" } ?? ""
      report.record(
        SetupReport.Name.githubTest, true, "\(response.scopes.count) scope(s) reachable\(login)")
    } catch {
      report.record(SetupReport.Name.githubTest, false, describe(error))
    }
  }

  private func printPermissionGuidance(_ response: GitHubTestResponse) {
    let io = deps.io
    io.say("")
    io.say("GitHub refused the credential. The daemon is installed and running, but it cannot")
    io.say("register a runner until this is fixed.")
    if let hint = response.auth.hint { io.say("  hint: \(hint)") }
    for scope in response.scopes where !scope.schedulable {
      for problem in scope.problems {
        io.say("  \(scope.name): \(problem.code): \(problem.detail)")
      }
    }
    io.say("")
    io.say("A fine-grained PAT needs Actions read/write (plus Administration read/write for an")
    io.say("organization scope); a classic PAT needs `repo` for a repository or `admin:org` for an")
    io.say("organization. Then:  sudo runnerctl auth login --token-stdin")
  }

  /// Pulls the Linux image and follows the operation. Nothing else depends on it, so a failure is
  /// recorded and the install continues — with the smoke test skipped, since there would be
  /// nothing to boot.
  private func imagePullStep(
    _ daemon: any SetupDaemon, plan: SetupPlan, report: inout SetupReport
  ) async -> Bool {
    guard plan.activeProfiles.contains(where: { $0.guestOS == .linux }) else {
      report.record(SetupReport.Name.imagePull, true, "skipped; no Linux profile")
      return false
    }
    do {
      let response = try await daemon.imagePull(reference: plan.linuxImage, format: nil)
      if response.alreadyPresent {
        report.record(SetupReport.Name.imagePull, true, "already present: \(response.reference)")
        return true
      }
      guard let operationId = response.operationId else {
        report.record(SetupReport.Name.imagePull, true, response.reference)
        return true
      }
      deps.io.say("pulling \(plan.linuxImage) …")
      let operation = try await waitForOperation(daemon, id: operationId)
      guard operation.state == "succeeded" else {
        let detail = [operation.errorCode, operation.errorMessage].compactMap { $0 }
          .joined(separator: ": ")
        report.record(
          SetupReport.Name.imagePull, false, detail.isEmpty ? operation.state : detail)
        return false
      }
      report.record(SetupReport.Name.imagePull, true, response.reference)
      return true
    } catch {
      report.record(SetupReport.Name.imagePull, false, describe(error))
      return false
    }
  }

  private func waitForOperation(
    _ daemon: any SetupDaemon, id: String
  ) async throws -> OperationInfo {
    while true {
      let operation = try await daemon.operationGet(id: id)
      guard operation.state == "running" || operation.state == "pending" else { return operation }
      try await deps.sleep(Self.operationPollInterval)
    }
  }

  private func configApplyStep(
    _ daemon: any SetupDaemon, plan: SetupPlan, report: inout SetupReport
  ) async {
    do {
      let response = try await daemon.configApply(yaml: plan.configFinal)
      // The daemon now holds the final document; make the file on disk match it, so a restart
      // and a `config apply --file` both see what is actually running.
      let staged = try deps.writeTemporary(plan.configFinal, "config.yaml")
      try await deps.runner.runChecked([Self.install, "-m", "0640", staged, plan.configPath])
      try await deps.runner.runChecked([Self.chown, plan.account.ownership, plan.configPath])
      let names = plan.activeProfiles.map(\.name).joined(separator: ", ")
      report.record(
        SetupReport.Name.configApply, true,
        names.isEmpty ? "no profiles" : "\(names) (\(response.diff.changeCount) change(s))")
    } catch {
      report.record(SetupReport.Name.configApply, false, describe(error))
    }
  }

  /// Boots one real instance of the Linux profile and proves the guest works, then destroys it.
  /// Skipped — and recorded as a failure, because the install could not prove itself — when there
  /// is no image to boot.
  private func smokeTestStep(
    _ daemon: any SetupDaemon, plan: SetupPlan, pulled: Bool, report: inout SetupReport
  ) async {
    guard let profile = plan.activeProfiles.first(where: { $0.guestOS == .linux }) else {
      report.record(SetupReport.Name.smokeTest, true, "skipped; no Linux profile")
      return
    }
    guard pulled else {
      report.record(SetupReport.Name.smokeTest, false, "skipped: the linux image was not pulled")
      return
    }
    guard report.step(named: SetupReport.Name.configApply)?.ok == true else {
      report.record(SetupReport.Name.smokeTest, false, "skipped: the profiles were not applied")
      return
    }
    deps.io.say("booting one \(profile.name) instance to verify the host …")
    let paths = RunnerPaths(
      rootDir: URL(fileURLWithPath: plan.stateDir, isDirectory: true),
      runtimeDir: URL(fileURLWithPath: plan.runtimeDir, isDirectory: true))
    let smoke = SmokeTest(client: daemon, paths: paths)
    let result = await smoke.run(SmokeTestOptions(profile: profile.name, macOS: false))
    let failed = result.checks.first { !$0.ok }
    report.record(
      SetupReport.Name.smokeTest, result.passed,
      result.passed
        ? "\(result.checks.count) check(s) passed"
        : failed.map { "\($0.name): \($0.detail)" } ?? "failed")
  }

  // MARK: - Summary

  private func finish(_ plan: SetupPlan, _ report: SetupReport) async -> SetupReport {
    var report = report
    if let planning = deps.runner as? PlanningCommandRunner {
      report.plannedCommands = await planning.planned
    }
    printSummary(plan, report)
    return report
  }

  private func printSummary(_ plan: SetupPlan, _ report: SetupReport) {
    let io = deps.io
    if dryRun {
      io.heading("Commands this would run")
      for command in report.plannedCommands { io.say("  \(command.joined(separator: " "))") }
      io.heading("\(plan.configPath) (bootstrap)")
      io.say(plan.configWithoutProfiles)
      io.heading("\(plan.configPath) (final, applied after the images are in place)")
      io.say(plan.configFinal)
    }

    io.heading(dryRun ? "Plan" : "Result")
    for line in report.ladder { io.say(line) }

    guard !plan.activeProfiles.isEmpty else { return }
    io.heading("Use it")
    io.say("Labels: \(plan.labels.joined(separator: ", "))")
    io.say("")
    io.say("jobs:")
    io.say("  build:")
    for profile in plan.activeProfiles {
      // Scale-set matching (the production default) is single-label: the scale set carries
      // exactly one label — the profile name — and a multi-label runs-on never matches it
      // (found live 2026-08-26, commit b9ab328). The [self-hosted, …] form is JIT-origin only.
      io.say("    runs-on: \(profile.name)")
    }
    io.say("")
    io.say("Then:  sudo runnerctl doctor        # full health check")
    io.say("       sudo runnerctl status        # capacity and live instances")
    if plan.managed.contains(where: { $0.kind == .macosTart }) {
      io.say("")
      // TODO(D7): drop this once the managed-image service can provision macOS itself; the macOS
      // profile block in the generated config carries the same instruction.
      io.say("macOS image provisioning lands with the managed-image service (D7): after it ships")
      for entry in plan.managed where entry.kind == .macosTart {
        io.say("run `sudo runnerctl image update run --managed \(entry.name)`, then uncomment the")
        io.say("macOS profile at the bottom of \(plan.configPath).")
      }
    }
  }

  private func describe(_ error: any Error) -> String {
    guard let runnerError = error as? any RunnerError else { return "\(error)" }
    return "\(runnerError.code): \(runnerError.message)"
  }
}
