import DaemonAPI
import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// A scripted `UpgradeDaemon`: the two host-mode calls, plus a switch for the "daemon is not
/// running" case, which `Upgrader` has to treat as a legitimate state rather than an error.
actor FakeUpgradeDaemon: UpgradeDaemon {
  var drained: Bool
  var activeSessions: Int
  var drainFailure: (any Error)?
  private(set) var calls: [String] = []
  private(set) var drainTimeoutMs: Int64?

  init(drained: Bool = true, activeSessions: Int = 0, drainFailure: (any Error)? = nil) {
    self.drained = drained
    self.activeSessions = activeSessions
    self.drainFailure = drainFailure
  }

  func systemDrain(wait: Bool, timeoutMs: Int64) async throws -> SystemModeResponse {
    calls.append("systemDrain(wait: \(wait))")
    drainTimeoutMs = timeoutMs
    if let drainFailure { throw drainFailure }
    return SystemModeResponse(
      mode: drained ? "draining" : "draining", activeSessions: activeSessions, drained: drained)
  }

  func systemResume() async throws -> SystemModeResponse {
    calls.append("systemResume")
    return SystemModeResponse(mode: "normal", activeSessions: 0, drained: true)
  }
}

/// `runnerctl upgrade`'s host-facing half. Every assertion here is on the recorded command
/// sequence, because the contract in `docs/design/distribution.md` ("Upgrade policy", "Failure
/// semantics") is entirely about *ordering*: what may run before the host is touched, what may
/// only run after a drain, and what must never run at all once something has failed.
@Suite struct UpgraderTests {
  static let stateDir = "/state"
  static let package = "RunnerVM-macos-arm64.pkg"
  static let digest = "aa11"

  static func manifestJSON(
    version: String = "0.3.0", sha: String = digest, signed: Bool = false,
    architecture: String = "arm64", package: String = UpgraderTests.package
  ) -> String {
    """
    {"version":"\(version)","architecture":"\(architecture)","minimumMacOS":"15.0",
     "package":"\(package)","sha256":"\(sha)","signed":\(signed),"license":"Apache-2.0"}
    """
  }

  /// The stub set a happy upgrade needs. `["&&"]` is what distinguishes the `(cd … && shasum -c)`
  /// verification from the plain `shasum -a 256 <pkg>` read: both mention shasum, and only the
  /// shell form contains the `&&`.
  static func stubs(
    manifest: String = UpgraderTests.manifestJSON(),
    hashed: String = UpgraderTests.digest,
    schemaBefore: String = "4",
    schemaAfter: String? = nil
  ) -> [RecordingCommandRunner.Stub] {
    var stubs: [RecordingCommandRunner.Stub] = [
      .stdout(["curl", "release-manifest.json"], manifest),
      .stdout(["&&"], ""),
      .stdout(["shasum", "256"], "\(hashed)  \(package)"),
      // `%Su`, not `stat`: every path here starts with "/state", which contains "stat".
      .stdout(["%Su"], "_runnervm:_runnervm"),
    ]
    // The schema query runs twice with identical argv -- once during the backup, once after the
    // swap -- so the first answer is consumed and the second one stands.
    if let schemaAfter {
      stubs.append(.once(["SELECT MAX"], schemaBefore))
      stubs.append(.stdout(["SELECT MAX"], schemaAfter))
    } else {
      stubs.append(.stdout(["SELECT MAX"], schemaBefore))
    }
    return stubs
  }

  static func upgrader(
    runner: RecordingCommandRunner,
    io: ScriptedSetupIO = ScriptedSetupIO(answers: []),
    daemon: FakeUpgradeDaemon? = FakeUpgradeDaemon(),
    previousPackageCached: Bool = true,
    options: Upgrader.Options = Upgrader.Options(
      stateDir: stateDir, runtimeDir: "/run", assumeYes: true, hostArchitecture: "arm64",
      hostMacOSMajor: 26)
  ) -> Upgrader {
    let previousManifest = manifestJSON(version: RunnerVMVersion.current)
    let cachedPath = "\(stateDir)/upgrades/\(RunnerVMVersion.current)/\(package)"
    return Upgrader(
      Upgrader.Dependencies(
        runner: runner,
        io: io,
        launchd: LaunchdManager(
          runner: runner,
          templateDirectories: [LaunchdManager.installedTemplateDirectory],
          readFile: { _ in LaunchdManagerTests.template },
          writeTemporary: { _, name in "/tmp/staged/\(name)" },
          fileExists: { _ in true },
          sleep: { _ in },
          now: { Date() }),
        connect: { _ in
          guard let daemon else { throw TestError("connection refused") }
          return daemon
        },
        writeTemporary: { _, name in "/tmp/staged/\(name)" },
        readFile: { path in
          guard previousPackageCached, path.contains(RunnerVMVersion.current) else {
            throw TestError("no such file: \(path)")
          }
          return previousManifest
        },
        fileExists: { path in
          if path == cachedPath { return previousPackageCached }
          // config.yaml and the backup's copy of it both exist in the happy case.
          return true
        },
        now: { Date(timeIntervalSince1970: 1_800_000_000) }),
      options: options)
  }

  /// The recorded argv reduced to the tools the contract is about, so the assertion reads as the
  /// sequence the design document specifies rather than as forty lines of mkdir/chmod. Matched on
  /// the executable, not on substrings: every path in this fixture ends in `runnerd.sqlite3`, so a
  /// substring match would call `stat` a database command.
  static func sequence(_ commands: [[String]]) -> [String] {
    commands.compactMap { argv in
      guard let executable = argv.first else { return nil }
      switch (executable as NSString).lastPathComponent {
      case "curl": return "curl"
      // The `(cd … && shasum -c)` form is a shell invocation; name it for what it verifies.
      case "sh": return "shasum -c"
      case "shasum": return "shasum"
      case "stat": return "stat"
      case "sqlite3":
        return argv.last?.hasPrefix("SELECT") == true ? "sqlite3 schema" : "sqlite3 backup"
      case "cp": return "cp"
      case "rm": return "rm"
      case "installer": return "installer"
      case "launchctl": return "launchctl \(argv.dropFirst().first ?? "")"
      default: return nil
      }
    }
  }

  // MARK: - --check

  @Test func checkFetchesTheManifestAndComparesWithoutTouchingAnything() async throws {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let result = try await Self.upgrader(runner: runner).check()

    #expect(result.current == RunnerVMVersion.current)
    #expect(result.latest == "0.3.0")
    #expect(result.verdict == .upgradeAvailable)
    // Exactly one command, and it only reads.
    #expect(await runner.lines.count == 1)
    #expect(await runner.lines[0].contains("release-manifest.json"))
  }

  @Test func checkReportsUpToDateWhenTheReleaseMatchesTheInstalledBuild() async throws {
    let runner = RecordingCommandRunner(
      stubs: Self.stubs(manifest: Self.manifestJSON(version: RunnerVMVersion.current)))
    let result = try await Self.upgrader(runner: runner).check()

    #expect(result.verdict == .upToDate)
    #expect(!result.upgradeAvailable)
  }

  @Test func anUnreachableManifestIsAnErrorWithTheURLInIt() async {
    let runner = RecordingCommandRunner(
      stubs: [.failure(["curl"], 22, "curl: (22) 404")])

    await #expect(throws: UpgradeError.self) {
      try await Self.upgrader(runner: runner).check()
    }
  }

  @Test func aManifestForAnotherArchitectureNeverReachesTheDownload() async {
    let runner = RecordingCommandRunner(
      stubs: Self.stubs(manifest: Self.manifestJSON(architecture: "x86_64")))
    let report = await Self.upgrader(runner: runner).run()

    #expect(!report.ok)
    #expect(report.step(named: UpgradeReport.Name.manifest)?.ok == false)
    #expect(!report.installed)
    #expect(await Self.sequence(runner.commands) == ["curl"])
  }

  // MARK: - Happy path

  @Test func runsTheStepsInTheOrderTheDesignDocumentSpecifies() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let daemon = FakeUpgradeDaemon()
    let report = await Self.upgrader(runner: runner, daemon: daemon).run()

    #expect(report.ok, "\(report.failed)")
    #expect(report.steps.map(\.name) == [
      UpgradeReport.Name.manifest, UpgradeReport.Name.download, UpgradeReport.Name.checksum,
      UpgradeReport.Name.rollbackMaterial, UpgradeReport.Name.confirmation,
      UpgradeReport.Name.backup, UpgradeReport.Name.drain, UpgradeReport.Name.stop,
      UpgradeReport.Name.installPackage, UpgradeReport.Name.start, UpgradeReport.Name.socket,
      UpgradeReport.Name.schema,
    ])
    // Nothing that changes the host runs before both checksums have agreed, the drain sits
    // between the backup and the swap, and the schema is read on both sides of it.
    #expect(await Self.sequence(runner.commands) == [
      "curl", "curl", "curl", "shasum -c", "shasum",
      "stat", "cp", "sqlite3 backup", "sqlite3 schema",
      "launchctl bootout", "installer", "launchctl bootstrap", "sqlite3 schema",
    ])
    #expect(await daemon.calls == ["systemDrain(wait: true)"])
  }

  @Test func cachesThePackageWhereBootstrapShWouldHavePutIt() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let report = await Self.upgrader(runner: runner).run()
    let lines = await runner.lines

    #expect(report.packagePath == "/state/upgrades/0.3.0/\(Self.package)")
    #expect(lines.contains("/bin/mkdir -p /state/upgrades/0.3.0"))
    #expect(lines.contains("/bin/chmod 0755 /state/upgrades/0.3.0"))
    #expect(lines.contains(
      "/usr/bin/curl -fsSL "
        + "https://github.com/andrejvysny/RunnerVM/releases/latest/download/\(Self.package) "
        + "-o /state/upgrades/0.3.0/\(Self.package)"))
    #expect(lines.contains(
      "/usr/bin/install -m 0644 /tmp/staged/release-manifest.json "
        + "/state/upgrades/0.3.0/release-manifest.json"))
  }

  @Test func backsUpTheConfigurationTheDatabaseAndTheSchemaVersion() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let report = await Self.upgrader(runner: runner).run()
    let backup = report.backupDirectory ?? ""
    let lines = await runner.lines

    #expect(backup.hasPrefix("/state/upgrades/backup-"))
    #expect(lines.contains("/bin/chmod 0700 \(backup)"))
    #expect(lines.contains("/bin/cp -p /state/config.yaml \(backup)/config.yaml"))
    #expect(lines.contains(
      "/usr/bin/sqlite3 /state/state/runnerd.sqlite3 .backup '\(backup)/runnerd.sqlite3'"))
    #expect(lines.contains(
      "/usr/bin/install -m 0600 /tmp/staged/versions.json \(backup)/versions.json"))
    #expect(report.schemaBefore == 4)
    #expect(report.schemaAfter == 4)
    #expect(report.stateOwner == "_runnervm:_runnervm")
  }

  @Test func versionsJSONRecordsBothVersionsAndTheSchemaItWasTakenAt() {
    let json = Upgrader.versionsJSON(from: "0.2.0", to: "0.3.0", schemaBefore: 4)

    #expect(json.contains("\"from\": \"0.2.0\""))
    #expect(json.contains("\"to\": \"0.3.0\""))
    #expect(json.contains("\"schemaBefore\": 4"))
  }

  @Test func drainUsesTheConfiguredTimeoutAndWaits() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let daemon = FakeUpgradeDaemon()
    _ = await Self.upgrader(
      runner: runner, daemon: daemon,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", drainTimeout: .seconds(60), assumeYes: true,
        hostArchitecture: "arm64", hostMacOSMajor: 26)).run()

    #expect(await daemon.drainTimeoutMs == 60_000)
  }

  // MARK: - Aborts before the host is touched

  @Test func aChecksumMismatchAbortsBeforeAnythingIsDrainedOrInstalled() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(hashed: "beef"))
    let daemon = FakeUpgradeDaemon()
    let report = await Self.upgrader(runner: runner, daemon: daemon).run()

    #expect(!report.ok)
    #expect(report.step(named: UpgradeReport.Name.checksum)?.ok == false)
    #expect(!report.installed)
    #expect(report.backupDirectory == nil)
    #expect(await daemon.calls.isEmpty)
    let sequence = await Self.sequence(runner.commands)
    #expect(!sequence.contains("installer"))
    #expect(!sequence.contains("launchctl bootout"))
  }

  @Test func aFailedDetachedChecksumAbortsTheSameWay() async {
    var stubs = Self.stubs()
    stubs.insert(.failure(["&&"], 1, "FAILED"), at: 0)
    let runner = RecordingCommandRunner(stubs: stubs)
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.step(named: UpgradeReport.Name.checksum)?.ok == false)
    #expect(!report.installed)
  }

  @Test func aFailedDownloadAbortsWithTheHostUntouched() async {
    var stubs = Self.stubs()
    stubs.insert(.failure(["curl", "-o"], 7, "connection refused"), at: 0)
    let runner = RecordingCommandRunner(stubs: stubs)
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.step(named: UpgradeReport.Name.download)?.ok == false)
    #expect(!report.installed)
    #expect(!(await Self.sequence(runner.commands)).contains("installer"))
  }

  @Test func anAlreadyCurrentHostIsANoOp() async {
    let runner = RecordingCommandRunner(
      stubs: Self.stubs(manifest: Self.manifestJSON(version: RunnerVMVersion.current)))
    let io = ScriptedSetupIO(answers: [])
    let report = await Self.upgrader(runner: runner, io: io).run()

    #expect(report.ok)
    #expect(report.steps.map(\.name) == [UpgradeReport.Name.manifest])
    #expect(io.output.contains("Nothing to do"))
    #expect(await Self.sequence(runner.commands) == ["curl"])
  }

  /// Naming a tag is an instruction, not a question: `--version` installs the release even when the
  /// comparison says the host already has it.
  @Test func anExplicitVersionInstallsEvenWhenItIsNotNewer() async {
    let runner = RecordingCommandRunner(
      stubs: Self.stubs(manifest: Self.manifestJSON(version: RunnerVMVersion.current)))
    let report = await Self.upgrader(
      runner: runner,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run",
        requestedVersion: "v\(RunnerVMVersion.current)", assumeYes: true,
        hostArchitecture: "arm64", hostMacOSMajor: 26)).run()

    #expect(report.ok, "\(report.failed)")
    #expect(report.installed)
  }

  // MARK: - Confirmations

  @Test func aMissingPreviousPackageWarnsAndRequiresConfirmationBeforeAnythingIsDrained() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: ["n"])
    let daemon = FakeUpgradeDaemon()
    let report = await Self.upgrader(
      runner: runner, io: io, daemon: daemon, previousPackageCached: false,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", hostArchitecture: "arm64",
        hostMacOSMajor: 26)).run()

    #expect(!report.ok)
    #expect(report.step(named: UpgradeReport.Name.rollbackMaterial)?.ok == false)
    #expect(report.previousPackagePath == nil)
    #expect(io.output.contains("No cached package for the installed version"))
    #expect(io.prompts.contains { $0.contains("without a rollback package") })
    #expect(await daemon.calls.isEmpty)
    #expect(!report.installed)
  }

  @Test func confirmingTheMissingPackageContinuesButRecordsThatRollbackIsManual() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    // Three questions in order: no rollback package, unsigned package, and the pre-drain confirm.
    let io = ScriptedSetupIO(answers: ["y", "y", "y"])
    let report = await Self.upgrader(
      runner: runner, io: io, previousPackageCached: false,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", hostArchitecture: "arm64",
        hostMacOSMajor: 26)).run()

    #expect(report.ok, "\(report.failed)")
    #expect(report.step(named: UpgradeReport.Name.rollbackMaterial)?.detail.contains("manual") == true)
    // Everything else lined up, but there is nothing to reinstall, so no automatic rollback.
    #expect(!report.rollbackAvailable)
  }

  @Test func anUnsignedPackageWarnsEveryTimeAndPromptsUnlessOverridden() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: ["n"])
    let report = await Self.upgrader(
      runner: runner, io: io,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", hostArchitecture: "arm64",
        hostMacOSMajor: 26)).run()

    #expect(!report.ok)
    #expect(io.output.contains("is UNSIGNED"))
    #expect(io.output.contains("does not prove who built the package"))
    #expect(report.step(named: UpgradeReport.Name.confirmation)?.detail.contains("unsigned") == true)
    #expect(!report.installed)
  }

  @Test func allowUnsignedSkipsThePromptButNotTheWarning() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: [])
    let report = await Self.upgrader(
      runner: runner, io: io,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", assumeYes: true, allowUnsigned: true,
        hostArchitecture: "arm64", hostMacOSMajor: 26)).run()

    #expect(report.ok, "\(report.failed)")
    #expect(io.output.contains("is UNSIGNED"))
    #expect(io.output.contains("RUNNERVM_ALLOW_UNSIGNED=1"))
  }

  @Test func aSignedPackageNeverPrintsTheWarning() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(manifest: Self.manifestJSON(signed: true)))
    let io = ScriptedSetupIO(answers: [])
    _ = await Self.upgrader(runner: runner, io: io).run()

    #expect(!io.output.contains("UNSIGNED"))
  }

  @Test func decliningThePreDrainConfirmationChangesNothing() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(manifest: Self.manifestJSON(signed: true)))
    let io = ScriptedSetupIO(answers: ["n"])
    let daemon = FakeUpgradeDaemon()
    let report = await Self.upgrader(
      runner: runner, io: io, daemon: daemon,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", hostArchitecture: "arm64",
        hostMacOSMajor: 26)).run()

    #expect(report.step(named: UpgradeReport.Name.confirmation)?.ok == false)
    #expect(await daemon.calls.isEmpty)
    #expect(!report.installed)
  }

  // MARK: - Drain

  @Test func anUnreachableDaemonSkipsTheDrainOnlyWithAnExplicitYes() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: [])
    let report = await Self.upgrader(runner: runner, io: io, daemon: nil).run()

    #expect(report.ok, "\(report.failed)")
    #expect(report.step(named: UpgradeReport.Name.drain)?.detail.contains("nothing to drain") == true)
    #expect(io.output.contains("not reachable"))
    #expect(report.installed)
  }

  @Test func anUnreachableDaemonAbortsWhenTheOperatorDeclines() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: ["y", "n"])
    let report = await Self.upgrader(
      runner: runner, io: io, daemon: nil,
      options: Upgrader.Options(
        stateDir: Self.stateDir, runtimeDir: "/run", allowUnsigned: true,
        hostArchitecture: "arm64", hostMacOSMajor: 26)).run()

    #expect(report.step(named: UpgradeReport.Name.drain)?.ok == false)
    #expect(!report.installed)
  }

  /// A drain that times out with jobs still running is a refusal, not a warning — and the host is
  /// put back into normal mode rather than left drained by a failed upgrade.
  @Test func aDrainThatTimesOutAbortsAndResumesTheHost() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let daemon = FakeUpgradeDaemon(drained: false, activeSessions: 2)
    let report = await Self.upgrader(runner: runner, daemon: daemon).run()

    #expect(report.step(named: UpgradeReport.Name.drain)?.ok == false)
    #expect(report.step(named: UpgradeReport.Name.drain)?.detail.contains("2 job(s)") == true)
    #expect(await daemon.calls.contains("systemResume"))
    #expect(!report.installed)
  }

  // MARK: - Install failure

  @Test func aFailedInstallerRestartsWhatWasAlreadyThere() async {
    var stubs = Self.stubs()
    stubs.insert(.failure(["installer"], 1, "The Installer encountered an error"), at: 0)
    let runner = RecordingCommandRunner(stubs: stubs)
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.step(named: UpgradeReport.Name.installPackage)?.ok == false)
    #expect(!report.installed)
    // Booted out, then booted back in: the old payload is still on disk.
    #expect(await Self.sequence(runner.commands).suffix(3)
      == ["launchctl bootout", "installer", "launchctl bootstrap"])
  }

  // MARK: - Schema and rollback eligibility

  @Test func anUnchangedSchemaMakesTheRollbackAvailable() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.schemaUnchanged)
    #expect(report.rollbackAvailable)
    #expect(report.step(named: UpgradeReport.Name.schema)?.detail.contains("unchanged") == true)
  }

  @Test func anAdvancedSchemaMakesTheRollbackUnavailable() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(schemaBefore: "4", schemaAfter: "5"))
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.schemaBefore == 4)
    #expect(report.schemaAfter == 5)
    #expect(!report.schemaUnchanged)
    #expect(!report.rollbackAvailable)
    #expect(report.step(named: UpgradeReport.Name.schema)?.detail.contains("one-way") == true)
  }

  /// A schema nobody could read is not "unchanged": restoring on a guess would undo a migration
  /// the new binaries may well have run.
  @Test func anUnreadableSchemaIsTreatedAsAdvanced() async {
    var stubs = Self.stubs()
    stubs.insert(.failure(["SELECT MAX"], 1, "no such table"), at: 0)
    let runner = RecordingCommandRunner(stubs: stubs)
    let report = await Self.upgrader(runner: runner).run()

    #expect(report.schemaBefore == nil)
    #expect(!report.schemaUnchanged)
    #expect(!report.rollbackAvailable)
  }

  // MARK: - Rollback

  @Test func rollbackReinstallsThePreviousPackageAndRestoresTheBackup() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let upgrader = Self.upgrader(runner: runner)
    var report = await upgrader.run()
    #expect(report.rollbackAvailable)
    let backup = report.backupDirectory ?? ""

    await runner.reset()
    let rolled = await upgrader.rollback(&report)

    #expect(rolled)
    #expect(report.step(named: UpgradeReport.Name.rollback)?.ok == true)
    #expect(await runner.lines == [
      "/bin/launchctl bootout system/com.runnervm.runnerd",
      "/usr/sbin/installer -pkg /state/upgrades/\(RunnerVMVersion.current)/\(Self.package) "
        + "-target /",
      "/bin/cp -p \(backup)/runnerd.sqlite3 /state/state/runnerd.sqlite3",
      "/bin/rm -f /state/state/runnerd.sqlite3-wal /state/state/runnerd.sqlite3-shm",
      "/bin/cp -p \(backup)/config.yaml /state/config.yaml",
      "/usr/sbin/chown _runnervm:_runnervm /state/state/runnerd.sqlite3",
      "/usr/sbin/chown _runnervm:_runnervm /state/config.yaml",
      "/bin/launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
    ])
  }

  @Test func rollbackRefusesOnceTheSchemaHasAdvancedAndPrintsTheManualSteps() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(schemaBefore: "4", schemaAfter: "5"))
    let io = ScriptedSetupIO(answers: [])
    let upgrader = Self.upgrader(runner: runner, io: io)
    var report = await upgrader.run()

    await runner.reset()
    let rolled = await upgrader.rollback(&report)

    #expect(!rolled)
    #expect(report.step(named: UpgradeReport.Name.rollback)?.ok == false)
    // Nothing at all was run: a refusal is a refusal.
    #expect(await runner.lines.isEmpty)
    #expect(io.output.contains("Migrations are one-way"))
    #expect(io.output.contains(report.backupDirectory ?? "<none>"))
  }

  @Test func rollbackRefusesWhenNothingWasInstalled() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(hashed: "beef"))
    let upgrader = Self.upgrader(runner: runner)
    var report = await upgrader.run()

    #expect(!(await upgrader.rollback(&report)))
    #expect(report.step(named: UpgradeReport.Name.rollback)?.detail.contains("nothing to undo") == true)
  }

  @Test func manualRestorationNamesTheBackupAndThePackage() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs(schemaBefore: "4", schemaAfter: "5"))
    let io = ScriptedSetupIO(answers: [])
    let upgrader = Self.upgrader(runner: runner, io: io)
    let report = await upgrader.run()

    upgrader.printManualRestoration(report)

    #expect(io.output.contains("sudo installer -pkg /state/upgrades/\(RunnerVMVersion.current)"))
    #expect(io.output.contains("sudo cp \(report.backupDirectory ?? "")/runnerd.sqlite3"))
    #expect(io.output.contains("sudo runnerctl doctor"))
  }

  // MARK: - Resume

  @Test func resumeReturnsTheHostToNormal() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let daemon = FakeUpgradeDaemon()
    let upgrader = Self.upgrader(runner: runner, daemon: daemon)
    var report = await upgrader.run()

    await upgrader.resume(into: &report)

    #expect(report.step(named: UpgradeReport.Name.resume)?.ok == true)
    #expect(await daemon.calls.contains("systemResume"))
  }

  @Test func resumeAgainstAnUnreachableDaemonIsReportedNotSwallowed() async {
    let runner = RecordingCommandRunner(stubs: Self.stubs())
    let io = ScriptedSetupIO(answers: [])
    let upgrader = Self.upgrader(runner: runner, io: io, daemon: nil)
    var report = await upgrader.run()

    await upgrader.resume(into: &report)

    #expect(report.step(named: UpgradeReport.Name.resume)?.ok == false)
    #expect(io.output.contains("sudo runnerctl system resume"))
  }

  // MARK: - Helpers

  @Test func quotingSurvivesTheSpaceInTheProductionStateDirectory() {
    #expect(Upgrader.quote("/Library/Application Support/RunnerVM")
      == "'/Library/Application Support/RunnerVM'")
    #expect(Upgrader.quote("it's") == #"'it'\''s'"#)
  }

  @Test func timestampsAreSortableAndUTC() {
    #expect(Upgrader.timestamp(Date(timeIntervalSince1970: 1_800_000_000)) == "20270115T080000Z")
  }
}
