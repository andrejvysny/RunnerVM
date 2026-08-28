import ArgumentParser
import DaemonAPI
import Foundation
import HostSetup
import RunnerCore

/// `sudo runnerctl upgrade` — the manual-only software upgrade
/// (`docs/design/distribution.md`, "Upgrade policy"). Nothing on a RunnerVM host ever upgrades
/// itself; this command is the only path.
///
/// Everything it does lives in `HostSetup.Upgrader`; this type is the flag surface, the root check,
/// the `doctor` verdict, and the one decision the design document reserves for the command layer:
/// whether a failed health check earns an automatic rollback.
struct UpgradeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upgrade",
    abstract: "Install a newer RunnerVM release on this host.",
    discussion: """
      Fetches release-manifest.json, verifies the pkg against both its detached .sha256 and the \
      manifest's own hash, backs up config.yaml and the database, drains the host, swaps the \
      package, restarts the daemon and runs doctor.

      Any download or checksum failure aborts before the host is touched. If doctor fails \
      afterwards and the database schema has not advanced, the cached previous package is \
      reinstalled and the backup restored automatically; if the schema did advance, migrations \
      are one-way, so the manual restoration steps are printed instead.

      Requires root (use sudo) unless --check, which only reports.
      """)

  @Flag(name: .long, help: "Report the installed and released versions, then stop. No root needed.")
  var check = false

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Install this tagged release instead of the latest one.",
      discussion: "vX.Y.Z. Naming a tag is an instruction: the same version, or an older one, "
        + "is installed rather than reported as a no-op."))
  var version: String?

  @Option(
    name: .long,
    help: "How long to let running jobs finish before giving up. 30m, 2h, 900s.")
  var drainTimeout: String = "30m"

  @Flag(
    name: [.long, .customShort("y")],
    help: "Answer every confirmation with yes, including the unsigned-package warning.")
  var yes = false

  @Option(name: .long, help: "Override the state directory.")
  var stateDir: String = SetupDefaults.stateDir

  @Option(name: .long, help: "Override the runtime (socket) directory.")
  var runtimeDir: String = SetupDefaults.runtimeDir

  func validate() throws {
    if let version, SemanticVersion(tag: version) == nil {
      throw ValidationError("--version must be a release tag like v0.3.0")
    }
    guard (try? DurationValue(parsing: drainTimeout)) != nil else {
      throw ValidationError("--drain-timeout must be a duration like 30m, 2h or 900s")
    }
    guard check || geteuid() == 0 else {
      throw ValidationError(UpgradeError.notRoot.message)
    }
  }

  func run() async throws {
    let io = TTYSetupIO()
    let upgrader = Upgrader(dependencies(io: io), options: resolvedOptions())

    guard !check else { return try await runCheck(upgrader) }

    var report = await upgrader.run()
    guard report.ok else {
      // Nothing was installed: the ladder already says where it stopped, and the host is
      // untouched. Only a failure *after* the swap is a recovery situation.
      guard report.installed else { throw ExitCode(1) }
      await recover(upgrader, &report)
      print("")
      print(report.ladder.joined(separator: "\n"))
      throw ExitCode(1)
    }

    let doctor = await runDoctor()
    guard !doctor.hasFailures else {
      let failed = doctor.checks.filter { $0.status == .fail }.map(\.title)
      report.record(UpgradeReport.Name.doctor, false, failed.joined(separator: ", "))
      print("")
      print(DoctorRender.render(doctor))
      await recover(upgrader, &report)
      print("")
      print(report.ladder.joined(separator: "\n"))
      throw ExitCode(1)
    }

    report.record(
      UpgradeReport.Name.doctor, true,
      "\(doctor.count(of: .ok)) ok, \(doctor.count(of: .warn)) warn")
    await upgrader.resume(into: &report)
    printSuccess(report)
  }

  // MARK: - --check

  private func runCheck(_ upgrader: Upgrader) async throws {
    let result = try await upgrader.check()
    print("installed:  \(result.current)")
    print("released:   \(result.latest)")
    print("package:    \(result.manifest.package) "
      + "(\(result.manifest.signed ? "signed" : "unsigned"), \(result.manifest.architecture), "
      + "macOS \(result.manifest.minimumMacOS)+)")
    print("verdict:    \(result.summary)")
    guard result.verdict == .upgradeAvailable else { return }
    print("")
    print("Install it with:  sudo runnerctl upgrade")
  }

  // MARK: - Post-upgrade verdict

  /// `doctor` against the host the new binaries are now running, with the service mode detected the
  /// same way `runnerctl doctor` detects it — a LaunchDaemon must not be judged by the
  /// login-keychain rules a foreground daemon is.
  private func runDoctor() async -> DoctorReport {
    print("")
    print("running doctor …")
    return await DoctorChecks.runAll(
      paths: paths, configPath: "\(stateDir)/config.yaml", daemonSocket: paths.daemonSocket,
      mode: DoctorChecks.detectServiceMode())
  }

  /// The one decision `docs/design/distribution.md` reserves for this layer: an automatic rollback
  /// happens only when the schema is provably unchanged *and* a cached previous package exists.
  /// It is not gated on `--yes`, and `--yes` does not enable it either — the schema is the gate,
  /// because a schema that advanced makes the restore itself the destructive act.
  private func recover(_ upgrader: Upgrader, _ report: inout UpgradeReport) async {
    guard report.rollbackAvailable else {
      upgrader.printManualRestoration(report)
      return
    }
    guard await upgrader.rollback(&report) else { return }
    // The host was drained for the upgrade and the old daemon is back: leaving it drained would
    // be a silent outage on top of a failed upgrade.
    await upgrader.resume(into: &report)
  }

  private func printSuccess(_ report: UpgradeReport) {
    print("")
    print(report.ladder.joined(separator: "\n"))
    print("")
    print("RunnerVM \(report.toVersion ?? "") is installed and the host is scheduling again.")
    if let backup = report.backupDirectory {
      print("The pre-upgrade backup is kept at \(backup).")
    }
  }

  // MARK: - Wiring

  private var paths: RunnerPaths {
    RunnerPaths(
      rootDir: URL(fileURLWithPath: stateDir, isDirectory: true),
      runtimeDir: URL(fileURLWithPath: runtimeDir, isDirectory: true))
  }

  private func resolvedOptions() -> Upgrader.Options {
    let mode = DoctorChecks.detectServiceMode()
    let timeout = (try? DurationValue(parsing: drainTimeout)) ?? .minutes(30)
    return Upgrader.Options(
      stateDir: stateDir,
      runtimeDir: runtimeDir,
      // A host with no launchd job at all is upgraded as if it were a LaunchDaemon: that is what
      // the pkg installs, and `bootout` of a job that was never loaded is a no-op anyway.
      mode: mode.mode == .agent ? .agent : .daemon,
      requestedVersion: version,
      packageURLOverride: ProcessInfo.processInfo.environment["RUNNERVM_PKG_URL"],
      drainTimeout: timeout.duration,
      assumeYes: yes,
      allowUnsigned: ProcessInfo.processInfo.environment["RUNNERVM_ALLOW_UNSIGNED"] == "1")
  }

  private func dependencies(io: any SetupIO) -> Upgrader.Dependencies {
    let runner = DefaultCommandRunner()
    return Upgrader.Dependencies(
      runner: runner,
      io: io,
      launchd: LaunchdManager(runner: runner),
      connect: { socketPath in
        try await DaemonClient.connect(socketPath: URL(fileURLWithPath: socketPath))
      })
  }
}
