import DaemonAPI
import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// Step ordering and failure semantics. `docs/design/distribution.md` ("Failure semantics") makes
/// exactly one distinction that matters here: a GitHub auth failure leaves the daemon installed
/// and running and is reported, while a step that would leave the host half-built aborts.
@Suite struct HostInstallerTests {
  static func plan(macOS: Bool = false, linux: Bool = true) -> SetupPlan {
    SetupPlanner.plan(
      answers: .stub(linuxEnabled: linux, macOSEnabled: macOS), facts: .stub())
  }

  /// A host where the account does not exist yet, every command succeeds, and the socket is there
  /// the moment it is looked for.
  static func dependencies(
    runner: any CommandRunner = ServiceAccountManagerTests.freshHost(),
    io: ScriptedSetupIO = ScriptedSetupIO(answers: []),
    daemon: FakeSetupDaemon = FakeSetupDaemon(),
    connectFails: Bool = false
  ) -> HostInstaller.Dependencies {
    HostInstaller.Dependencies(
      runner: runner,
      io: io,
      accounts: ServiceAccountManager(runner: runner),
      launchd: LaunchdManager(
        runner: runner,
        templateDirectories: [LaunchdManager.installedTemplateDirectory],
        readFile: { _ in LaunchdManagerTests.template },
        writeTemporary: { _, name in "/tmp/staged/\(name)" },
        fileExists: { _ in true },
        sleep: { _ in },
        now: { Date() }),
      connect: { _ in
        if connectFails { throw TestError("connection refused") }
        return daemon
      },
      writeTemporary: { _, name in "/tmp/staged/\(name)" },
      sleep: { _ in })
  }

  private func names(_ report: SetupReport) -> [String] { report.steps.map(\.name) }

  // MARK: - Happy path

  @Test func runsEveryStepInOrder() async {
    let report = await HostInstaller(Self.dependencies()).install(Self.plan(), token: "ghp_x")

    #expect(report.ok, "\(report.failed)")
    #expect(names(report) == [
      SetupReport.Name.account, SetupReport.Name.directories, SetupReport.Name.config,
      SetupReport.Name.launchd, SetupReport.Name.socket, SetupReport.Name.auth,
      SetupReport.Name.githubTest, SetupReport.Name.imagePull, SetupReport.Name.configApply,
      SetupReport.Name.smokeTest,
    ])
  }

  @Test func writesTheBootstrapDocumentFirstAndTheFinalOneAfterTheImageIsThere() async throws {
    let daemon = FakeSetupDaemon()
    let plan = Self.plan()
    _ = await HostInstaller(Self.dependencies(daemon: daemon)).install(plan, token: "ghp_x")

    // The daemon is handed the document that has the profiles in it, not the bootstrap one.
    let applied = try #require(await daemon.appliedYAML)
    #expect(applied == plan.configFinal)
    #expect(applied.contains("rvm-ab12cd-ubuntu-24"))
    #expect(!plan.configWithoutProfiles.contains("\nprofiles:"))
  }

  @Test func createsTheStateLayoutOwnedByTheServiceAccount() async {
    let runner = ServiceAccountManagerTests.freshHost()
    _ = await HostInstaller(Self.dependencies(runner: runner)).install(Self.plan(), token: "")

    let lines = await runner.lines
    for directory in ["images", "instances", "logs/instances", "logs/builds", "logs/runnerd",
                      "state/builds", "cache/base-images"] {
      #expect(lines.contains(
        "/bin/mkdir -p /Library/Application Support/RunnerVM/\(directory)"),
        "missing \(directory)")
    }
    #expect(lines.contains("/bin/chmod 0700 /var/run/runnervm"))
    #expect(lines.contains(
      "/usr/sbin/chown _runnervm:_runnervm /Library/Application Support/RunnerVM/config.yaml"))
    #expect(lines.contains(
      "/usr/bin/install -m 0640 /tmp/staged/config.yaml "
        + "/Library/Application Support/RunnerVM/config.yaml"))
  }

  @Test func printsTheRunsOnSampleAndTheLabels() async {
    let io = ScriptedSetupIO(answers: [])
    _ = await HostInstaller(Self.dependencies(io: io)).install(Self.plan(), token: "ghp_x")

    #expect(io.output.contains("Labels: self-hosted, rvm-ab12cd-ubuntu-24"))
    #expect(io.output.contains("runs-on: rvm-ab12cd-ubuntu-24"))
    #expect(io.output.contains("runnerctl doctor"))
  }

  @Test func aProvisionedMacOSProfileJoinsTheRunsOnSample() async {
    let io = ScriptedSetupIO(answers: [])
    _ = await HostInstaller(Self.dependencies(io: io))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(io.output.contains("Labels: self-hosted, rvm-ab12cd-ubuntu-24, rvm-ab12cd-macos-tahoe"))
    #expect(io.output.contains("runs-on: rvm-ab12cd-macos-tahoe"))
    // Nothing to retry: the profile is live.
    #expect(!io.output.contains("image update run --managed"))
  }

  @Test func aFailedMacOSProvisioningRunPrintsTheRetryCommand() async {
    let io = ScriptedSetupIO(answers: [])
    let daemon = FakeSetupDaemon(updateStates: ["building", "failed"], updateError: "seal failed")
    _ = await HostInstaller(Self.dependencies(io: io, daemon: daemon))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(io.output.contains("still a working Linux runner host"))
    #expect(io.output.contains("sudo runnerctl image update run --managed macos-tahoe-base"))
    #expect(!io.output.contains("runs-on: rvm-ab12cd-macos-tahoe"))
  }

  // MARK: - Token handling

  @Test func anAbsentTokenSkipsAuthAndGitHubWithoutFailingTheInstall() async {
    let daemon = FakeSetupDaemon()
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "")

    #expect(report.ok)
    #expect(!names(report).contains(SetupReport.Name.githubTest))
    #expect(report.step(named: SetupReport.Name.auth)?.detail.contains("auth login") == true)
    #expect(await daemon.calls.contains("authLogin") == false)
  }

  @Test func theTokenGoesToTheDaemonNeverIntoTheYAML() async {
    let daemon = FakeSetupDaemon()
    let plan = Self.plan()
    _ = await HostInstaller(Self.dependencies(daemon: daemon)).install(plan, token: "ghp_secret")

    #expect(await daemon.loggedInToken == "ghp_secret")
    #expect(!plan.configFinal.contains("ghp_secret"))
    #expect(!plan.configWithoutProfiles.contains("ghp_secret"))
  }

  // MARK: - Failure semantics

  /// The contract: the daemon stays installed and running, the install continues, and the exact
  /// permission text the operator has to act on is printed.
  @Test func aGitHubPermissionFailureIsReportedButDoesNotStopTheInstall() async {
    let io = ScriptedSetupIO(answers: [])
    let daemon = FakeSetupDaemon(githubTestResult: .value(.stubForbidden()))
    let report = await HostInstaller(Self.dependencies(io: io, daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(!report.ok)
    #expect(report.step(named: SetupReport.Name.githubTest)?.ok == false)
    #expect(report.step(named: SetupReport.Name.githubTest)?.detail.contains("GITHUB_FORBIDDEN")
      == true)
    // Everything after it still ran.
    #expect(report.step(named: SetupReport.Name.imagePull)?.ok == true)
    #expect(report.step(named: SetupReport.Name.configApply)?.ok == true)
    #expect(io.output.contains("cannot administer runners on acme/widgets"))
    #expect(io.output.contains("admin:org"))
  }

  @Test func aFailedTokenStoreSkipsTheGitHubProbe() async {
    let daemon = FakeSetupDaemon(authLoginResult: .failure(TestError("keychain locked")))
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(report.step(named: SetupReport.Name.auth)?.ok == false)
    #expect(!names(report).contains(SetupReport.Name.githubTest))
    #expect(report.step(named: SetupReport.Name.configApply)?.ok == true)
  }

  /// Nothing to boot means the smoke test cannot prove anything, so it is recorded as a failure
  /// rather than quietly passing.
  @Test func aFailedImagePullSkipsTheSmokeTest() async {
    let daemon = FakeSetupDaemon(operationStates: ["running", "failed"])
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(!report.ok)
    #expect(report.step(named: SetupReport.Name.imagePull)?.ok == false)
    #expect(report.step(named: SetupReport.Name.imagePull)?.detail.contains("IMAGE_PULL_FAILED")
      == true)
    let smoke = report.step(named: SetupReport.Name.smokeTest)
    #expect(smoke?.ok == false)
    #expect(smoke?.detail.contains("skipped") == true)
  }

  @Test func anImageAlreadyInTheStoreIsNotPulledAgain() async {
    let daemon = FakeSetupDaemon(imagePullResult: .value(ImagePullResponse(
      reference: "ghcr.io/andrejvysny/runnervm/ubuntu-24-base@sha256:abc",
      manifestDigest: "sha256:abc", operationId: nil, alreadyPresent: true,
      digest: "sha256:abc")))
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(report.ok)
    #expect(report.step(named: SetupReport.Name.imagePull)?.detail.contains("already present")
      == true)
    #expect(await !daemon.calls.contains("operationGet"))
  }

  @Test func aFailedConfigApplySkipsTheSmokeTest() async {
    let daemon = FakeSetupDaemon(configApplyResult: .failure(TestError("profile refused")))
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(report.step(named: SetupReport.Name.configApply)?.ok == false)
    #expect(report.step(named: SetupReport.Name.smokeTest)?.detail.contains("not applied") == true)
  }

  @Test func aFailedSmokeTestIsReportedWithTheCheckThatFailed() async {
    let daemon = FakeSetupDaemon(smokeTestPasses: false)
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(!report.ok)
    #expect(report.step(named: SetupReport.Name.smokeTest)?.detail.contains("instance.create")
      == true)
  }

  /// A host-level step failing means the next one would operate on a half-built host, so the run
  /// stops there.
  @Test func aFailedAccountStepAbortsBeforeAnythingElseIsTouched() async {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187),
      .stdout(["-list", "/Groups"], ServiceAccountManagerTests.groupList(upTo: 400)),
    ])
    let report = await HostInstaller(Self.dependencies(runner: runner))
      .install(Self.plan(), token: "ghp_x")

    #expect(names(report) == [SetupReport.Name.account])
    #expect(report.step(named: SetupReport.Name.account)?.detail.contains("SETUP_NO_FREE_ID")
      == true)
  }

  @Test func aFailedLaunchdInstallStopsBeforeTheSocketWait() async {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187),
      .failure(["-read", "/Users/_runnervm"], 187),
      .stdout(["-list", "/Groups"], ServiceAccountManagerTests.groupList(upTo: 205)),
      .stdout(["-list", "/Users"], ServiceAccountManagerTests.userList(upTo: 205)),
      .failure(["-lint"], 1, "Unexpected character"),
    ])
    let report = await HostInstaller(Self.dependencies(runner: runner))
      .install(Self.plan(), token: "ghp_x")

    #expect(names(report).last == SetupReport.Name.launchd)
    #expect(report.step(named: SetupReport.Name.launchd)?.ok == false)
  }

  @Test func aDaemonThatNeverAcceptsAConnectionIsReportedAgainstTheSocketStep() async {
    let report = await HostInstaller(Self.dependencies(connectFails: true))
      .install(Self.plan(), token: "ghp_x")

    #expect(!report.ok)
    #expect(names(report).last == SetupReport.Name.connect)
    #expect(report.step(named: SetupReport.Name.socket)?.ok == true)
    #expect(report.step(named: SetupReport.Name.connect)?.detail.contains("connection refused")
      == true)
  }

  // MARK: - Dry run

  @Test func aDryRunTouchesNothingAndNeverReachesTheDaemon() async {
    let recorder = RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187),
      .failure(["-read", "/Users/_runnervm"], 187),
      .stdout(["-list", "/Groups"], ServiceAccountManagerTests.groupList(upTo: 205)),
      .stdout(["-list", "/Users"], ServiceAccountManagerTests.userList(upTo: 205)),
    ])
    let planner = PlanningCommandRunner(underlying: recorder)
    let daemon = FakeSetupDaemon()
    let io = ScriptedSetupIO(answers: [])
    let deps = Self.dependencies(runner: planner, io: io, daemon: daemon)

    let report = await HostInstaller(deps, dryRun: true).install(Self.plan(), token: "ghp_x")

    #expect(report.dryRun)
    #expect(await daemon.calls.isEmpty)
    #expect(!names(report).contains(SetupReport.Name.socket))
    // Only read-only probes actually ran; every mutation was collected instead. `plutil -lint`
    // is deliberately among them: a dry run still proves the rendered plist parses.
    let executed = await recorder.lines
    #expect(executed.allSatisfy {
      $0.contains("-read") || $0.contains("-list") || $0.contains("plutil -lint")
    })
    #expect(!executed.contains { $0.contains("-create") || $0.contains("mkdir") })
    #expect(report.plannedCommands.contains { $0.contains("/Users/_runnervm") })
    #expect(report.plannedCommands.contains { $0.contains("bootstrap") })
    // The operator sees both documents before deciding.
    #expect(io.output.contains("Commands this would run"))
    #expect(io.output.contains("(bootstrap)"))
    #expect(io.output.contains("(final, applied after the images are in place)"))
  }

  // MARK: - macOS provisioning

  /// The tail `setup --macos` adds: provision the managed image, size the profile to it, apply a
  /// third document, then prove the result by booting it.
  @Test func provisionsSizesActivatesAndProvesTheMacOSProfile() async throws {
    let daemon = FakeSetupDaemon(updateStates: ["checking", "building", "qualifying", "idle"])
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(report.ok, "\(report.failed)")
    #expect(names(report).suffix(3) == [
      SetupReport.Name.macOSImage, SetupReport.Name.macOSProfile,
      SetupReport.Name.macOSSmokeTest,
    ])
    let calls = await daemon.calls
    #expect(calls.contains("imageUpdateRun(macos-tahoe-base)"))
    // Asked for by the promoted digest, not by the alias: the track already knows which bytes won.
    #expect(calls.contains("imageGet(sha256:macos)"))
  }

  /// The exact virtual size, in bytes, with the `B` suffix that keeps it a YAML string: a macOS
  /// guest cannot resize its APFS container, so a rounded number is an unbootable profile.
  @Test func theThirdDocumentCarriesTheProfileSizedToTheImage() async throws {
    let daemon = FakeSetupDaemon()
    let plan = Self.plan(macOS: true)
    _ = await HostInstaller(Self.dependencies(daemon: daemon)).install(plan, token: "ghp_x")

    let documents = await daemon.appliedDocuments
    #expect(documents.count == 2)
    #expect(documents[0] == plan.configFinal)
    // The first apply still has the profile commented out; the second one activates it.
    #expect(!documents[0].contains("\n  - name: rvm-ab12cd-macos-tahoe"))
    #expect(documents[1].contains("  - name: rvm-ab12cd-macos-tahoe"))
    #expect(documents[1].contains("      disk: 68719479808B"))
    #expect(!documents[1].contains("# macOS profile — activate after"))
    // And the file on disk is rewritten to match what the daemon now holds.
    #expect(documents[1] == plan.configActivatingMacOS(diskBytes: 68_719_479_808))
  }

  @Test func aFailedProvisioningRunLeavesTheLinuxHalfIntact() async {
    let daemon = FakeSetupDaemon(updateStates: ["building", "failed"], updateError: "seal failed")
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(!report.ok)
    #expect(report.step(named: SetupReport.Name.macOSImage)?.detail == "seal failed")
    // Nothing past the failed step ran, and the Linux install is untouched.
    #expect(report.step(named: SetupReport.Name.macOSProfile) == nil)
    #expect(report.step(named: SetupReport.Name.smokeTest)?.ok == true)
    #expect(report.step(named: SetupReport.Name.configApply)?.ok == true)
    #expect(await daemon.appliedDocuments.count == 1)
  }

  @Test func aRunThatNeverSettlesTimesOutRatherThanWaitingForever() async {
    let daemon = FakeSetupDaemon(updateStates: ["building"])
    let report = await HostInstaller(
      Self.dependencies(daemon: daemon),
      macOSTimeout: .seconds(60), macOSPollInterval: .seconds(15))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(report.step(named: SetupReport.Name.macOSImage)?.ok == false)
    #expect(report.step(named: SetupReport.Name.macOSImage)?.detail.contains("still building") == true)
    // Five status polls: one per interval up to the timeout, plus the one that reports it.
    #expect(await daemon.calls.filter { $0 == "imageUpdateStatus" }.count == 5)
    #expect(await daemon.appliedDocuments.count == 1)
  }

  @Test func aRunThatFinishesWithoutPromotingAnImageIsAFailure() async {
    let daemon = FakeSetupDaemon(promotedDigest: nil, updateError: "qualification failed")
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(macOS: true), token: "ghp_x")

    #expect(report.step(named: SetupReport.Name.macOSImage)?.ok == false)
    #expect(report.step(named: SetupReport.Name.macOSImage)?.detail == "qualification failed")
  }

  @Test func aPlanWithoutMacOSNeverTouchesTheImageUpdateService() async {
    let daemon = FakeSetupDaemon()
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(), token: "ghp_x")

    #expect(!names(report).contains(SetupReport.Name.macOSImage))
    #expect(await !daemon.calls.contains { $0.hasPrefix("imageUpdate") })
  }

  // MARK: - No Linux profile

  @Test func aPlanWithNoLinuxProfileSkipsThePullAndTheSmokeTest() async {
    let daemon = FakeSetupDaemon()
    let report = await HostInstaller(Self.dependencies(daemon: daemon))
      .install(Self.plan(linux: false), token: "ghp_x")

    #expect(report.ok)
    #expect(await !daemon.calls.contains { $0.hasPrefix("imagePull") })
    #expect(report.step(named: SetupReport.Name.imagePull)?.detail.contains("no Linux profile")
      == true)
    #expect(report.step(named: SetupReport.Name.smokeTest)?.detail.contains("no Linux profile")
      == true)
  }
}
