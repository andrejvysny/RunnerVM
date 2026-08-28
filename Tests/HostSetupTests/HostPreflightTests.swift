import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// The preflight's parsers, against the exact text the tools it shells out to produce. Acquisition
/// goes through `CommandRunner`, so the whole gather is exercised without touching the host.
@Suite struct HostPreflightTests {
  /// Trimmed from a real `ioreg -rd1 -c IOPlatformExpertDevice` on an M4 Mac mini.
  static let ioregOutput = """
  +-o J773AAP  <class IOPlatformExpertDevice, id 0x100000268, registered, matched, active>
      {
        "IOPolledInterface" = "AppleARMWatchdogTimerHibernateHandler is not serializable"
        "IOPlatformUUID" = "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77"
        "platform-name" = <"t8132">
        "model" = <"Mac16,10">
        "IOPlatformSerialNumber" = "XYZ1234567"
      }
  """

  // MARK: - Platform UUID and host id

  @Test func parsesThePlatformUUIDOutOfIoregOutput() {
    #expect(HostPreflight.parsePlatformUUID(ioregOutput: Self.ioregOutput)
      == "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77")
  }

  @Test func returnsNoPlatformUUIDWhenIoregPrintedNothingUsable() {
    #expect(HostPreflight.parsePlatformUUID(ioregOutput: "") == nil)
    #expect(HostPreflight.parsePlatformUUID(ioregOutput: "+-o J773AAP <class …>") == nil)
  }

  /// The whole point of `host6` is that it never moves for a given Mac: the default profile name,
  /// and therefore the scale-set session this host claims, is derived from it.
  @Test func hostIDIsSixLowercaseHexCharactersAndStable() {
    let first = HostPreflight.hostID6(platformUUID: "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77")
    let second = HostPreflight.hostID6(platformUUID: "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77")
    #expect(first == second)
    #expect(first.count == 6)
    #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    // It is a hash, not a truncation: the UUID itself must not be recoverable from a runner name.
    #expect(!"0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77".lowercased().hasPrefix(first))
  }

  @Test func differentMacsGetDifferentHostIDs() {
    #expect(HostPreflight.hostID6(platformUUID: "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77")
      != HostPreflight.hostID6(platformUUID: "11111111-2222-3333-4444-555555555555"))
  }

  @Test func hostIDIsDerivedStraightFromIoregOutput() {
    #expect(HostPreflight.hostID6(ioregOutput: Self.ioregOutput)
      == HostPreflight.hostID6(platformUUID: "0E4E0D1F-7C2B-5A64-9E31-2F5C1D8B4A77"))
    #expect(HostPreflight.hostID6(ioregOutput: "nothing here") == nil)
  }

  // MARK: - FileVault

  @Test func fileVaultOffIsParsedAndCarriesNoWarning() {
    let status = FileVaultStatus.parse(output: "FileVault is Off.\n", exitCode: 0)
    #expect(status == .off)
    #expect(status.warning == nil)
  }

  @Test func fileVaultOnIsParsedAndWarnsAboutColdBoot() throws {
    let status = FileVaultStatus.parse(output: "FileVault is On.\n", exitCode: 0)
    #expect(status == .on)
    let warning = try #require(status.warning)
    #expect(warning.contains("pre-boot authentication"))
  }

  @Test(arguments: [("", Int32(0)), ("FileVault is On.", Int32(1)), ("something else", Int32(0))])
  func unreadableFileVaultStatusIsUnknownRatherThanGuessed(_ fixture: (String, Int32)) {
    #expect(FileVaultStatus.parse(output: fixture.0, exitCode: fixture.1) == .unknown)
    #expect(FileVaultStatus.unknown.warning != nil)
  }

  // MARK: - Whole gather

  private static func runner(fileVault: String = "FileVault is Off.") -> RecordingCommandRunner {
    RecordingCommandRunner(stubs: [
      .stdout(["hw.model"], "Mac16,10\n"),
      .stdout(["hw.logicalcpu"], "10\n"),
      .stdout(["hw.memsize"], "25769803776\n"),
      .stdout(["hw.optional.arm64"], "1\n"),
      .stdout(["sw_vers"], "26.5.2\n"),
      .stdout(["ioreg"], ioregOutput),
      .stdout(["fdesetup"], fileVault),
    ])
  }

  @Test func gathersEveryFactThroughTheCommandRunner() async {
    let facts = await HostPreflight(
      runner: Self.runner(), fileExists: { _ in false },
      freeDisk: { _ in ByteSize.gibibytes(200).bytes })
      .gather(stateDir: "/state", configPath: "/state/config.yaml")

    #expect(facts.model == "Mac16,10")
    #expect(facts.cpuCount == 10)
    #expect(facts.memoryBytes == ByteSize.gibibytes(24).bytes)
    #expect(facts.freeDiskBytes == ByteSize.gibibytes(200).bytes)
    #expect(facts.macOSVersion == "26.5.2")
    #expect(facts.isAppleSilicon)
    #expect(facts.hostID6 == HostPreflight.hostID6(ioregOutput: Self.ioregOutput))
    #expect(facts.fileVault == .off)
    #expect(!facts.existingInstall.isPresent)
  }

  /// An Intel Mac reports no `hw.optional.arm64`, which `sysctl` answers with a non-zero exit.
  @Test func anIntelHostIsReportedAsNotAppleSilicon() async {
    let runner = RecordingCommandRunner(
      stubs: [.failure(["hw.optional.arm64"], 1, "unknown oid")],
      fallback: CommandResult(exitCode: 0, stdout: "MacBookPro16,1"))
    let facts = await HostPreflight(
      runner: runner, fileExists: { _ in false }, freeDisk: { _ in 0 })
      .gather(stateDir: "/state", configPath: "/state/config.yaml")
    #expect(!facts.isAppleSilicon)
  }

  @Test func anExistingInstallIsDetectedAndSummarized() async {
    let present: Set<String> = [
      "/state", "/state/config.yaml", HostPreflight.daemonPlistPath,
    ]
    let facts = await HostPreflight(
      runner: Self.runner(), fileExists: { present.contains($0) }, freeDisk: { _ in 0 })
      .gather(stateDir: "/state", configPath: "/state/config.yaml")

    #expect(facts.existingInstall.isPresent)
    #expect(facts.existingInstall.stateDirectory)
    #expect(facts.existingInstall.configFile)
    #expect(facts.existingInstall.daemonPlist)
    #expect(!facts.existingInstall.agentPlist)
    #expect(facts.existingInstall.summary == "state directory, config.yaml, launchdaemon")
  }

  /// Every probe the preflight runs is read-only, so a `--dry-run` on an unprivileged shell still
  /// produces real facts rather than a plan full of blanks.
  @Test func everyPreflightCommandIsReadOnly() async throws {
    let recorder = Self.runner()
    let planner = PlanningCommandRunner(underlying: recorder)
    _ = await HostPreflight(runner: planner, fileExists: { _ in false }, freeDisk: { _ in 0 })
      .gather(stateDir: "/state", configPath: "/state/config.yaml")
    #expect(await planner.planned.isEmpty)
    #expect(await recorder.commands.count == 7)
  }
}
