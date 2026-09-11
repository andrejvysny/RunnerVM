import Foundation
import RunnerCore
import Testing

/// The launchd half of `runnerctl doctor`, against recorded `launchctl print` output and real
/// property lists. Nothing here shells out: the `launchctl` call and the directory `stat` live in
/// `runnerctl`, which has no test target.
@Suite struct DoctorLaunchdTests {
  /// A daemon that started once and is still up.
  private static let healthyPrint = """
    system/com.runnervm.runnerd = {
    \tactive count = 1
    \tpath = /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
    \ttype = LaunchDaemon
    \tstate = running
    \tprogram = /usr/local/bin/runnerd
    \truns = 1
    \tpid = 4711
    \tforks = 0
    \texecs = 1
    \tlast exit code = 0
    }
    """

  /// blackpen, 2026-08: launchd could not spawn the daemon at all, so it kept trying.
  private static let crashLoopPrint = """
    system/com.runnervm.runnerd = {
    \tactive count = 0
    \tpath = /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
    \ttype = LaunchDaemon
    \tstate = spawn scheduled
    \tprogram = /usr/local/bin/runnerd
    \truns = 70547
    \tlast exit code = 78
    }
    """

  /// The shape `packaging/launchd/com.runnervm.runnerd.daemon.plist` installs, trimmed to the keys
  /// doctor reads.
  private static let stdioPlist = Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.runnervm.runnerd</string>
        <key>ThrottleInterval</key>
        <integer>30</integer>
        <key>StandardOutPath</key>
        <string>/Library/Application Support/RunnerVM/logs/runnerd/stdio.log</string>
        <key>StandardErrorPath</key>
        <string>/Library/Application Support/RunnerVM/logs/runnerd/stdio.log</string>
    </dict>
    </plist>
    """.utf8)

  // MARK: launchctl print

  @Test func healthyJobReportsItsCounters() {
    let facts = DoctorLaunchd.jobFacts(fromLaunchctlPrint: Self.healthyPrint)
    #expect(facts == DoctorLaunchd.JobFacts(runs: 1, lastExitCode: 0))
    let check = DoctorLaunchd.jobCheck(
      loaded: "LaunchDaemon com.runnervm.runnerd loaded in system", facts: facts,
      stdioLogPath: nil)
    #expect(check.id == "launchd_job")
    #expect(check.status == .ok)
  }

  @Test func crashLoopWarnsNamingRunsAndTheExitCode() {
    let facts = DoctorLaunchd.jobFacts(fromLaunchctlPrint: Self.crashLoopPrint)
    #expect(facts == DoctorLaunchd.JobFacts(runs: 70547, lastExitCode: 78))
    let check = DoctorLaunchd.jobCheck(
      loaded: "LaunchDaemon com.runnervm.runnerd loaded in system", facts: facts,
      stdioLogPath: "/Library/Application Support/RunnerVM/logs/runnerd/stdio.log")
    #expect(check.status == .warn)
    #expect(check.detail.contains("70547"))
    #expect(check.detail.contains("78"))
    #expect(check.detail.contains("stdio.log"))
  }

  @Test func aFailedLastExitWarnsEvenAfterOneRun() {
    let check = DoctorLaunchd.jobCheck(
      loaded: "loaded", facts: DoctorLaunchd.JobFacts(runs: 2, lastExitCode: 72),
      stdioLogPath: nil)
    #expect(check.status == .warn)
    #expect(check.detail.contains("stdio.log"))
  }

  @Test func respawnsAloneWarnWithoutAFailedExit() {
    let check = DoctorLaunchd.jobCheck(
      loaded: "loaded", facts: DoctorLaunchd.JobFacts(runs: 11, lastExitCode: 0),
      stdioLogPath: nil)
    #expect(check.status == .warn)
  }

  /// launchd words this field rather than numbering it on a job that has never exited; "unknown"
  /// is not a failure.
  @Test func aNeverExitedJobParsesAsUnknownAndStaysOK() {
    let facts = DoctorLaunchd.jobFacts(
      fromLaunchctlPrint: "\truns = 1\n\tlast exit code = (never exited)\n")
    #expect(facts == DoctorLaunchd.JobFacts(runs: 1, lastExitCode: nil))
    let check = DoctorLaunchd.jobCheck(loaded: "loaded", facts: facts, stdioLogPath: nil)
    #expect(check.status == .ok)
    #expect(check.detail.contains("unknown"))
  }

  @Test func outputWithoutEitherCounterIsUnknownRatherThanZero() {
    let facts = DoctorLaunchd.jobFacts(fromLaunchctlPrint: "system/x = {\n\tstate = running\n}")
    #expect(facts == DoctorLaunchd.JobFacts(runs: nil, lastExitCode: nil))
  }

  // MARK: plists

  @Test func plistFactsComeFromEitherSerializationFormat() throws {
    let binary = try PropertyListSerialization.data(
      fromPropertyList: ["StandardOutPath": "/tmp/a/stdio.log", "ThrottleInterval": 5],
      format: .binary, options: 0)
    #expect(
      DoctorLaunchd.plistFacts(fromPropertyList: Self.stdioPlist)
        == DoctorLaunchd.PlistFacts(
          standardOutPath: "/Library/Application Support/RunnerVM/logs/runnerd/stdio.log",
          standardErrorPath: "/Library/Application Support/RunnerVM/logs/runnerd/stdio.log",
          throttleInterval: 30))
    #expect(
      DoctorLaunchd.plistFacts(fromPropertyList: binary)
        == DoctorLaunchd.PlistFacts(standardOutPath: "/tmp/a/stdio.log", throttleInterval: 5))
    #expect(DoctorLaunchd.plistFacts(fromPropertyList: Data("not a plist".utf8)) == nil)
  }

  @Test func aMissingStdioDirectoryFailsWithTheRemedy() {
    let check = DoctorLaunchd.stdioDirectoryCheck(
      plistPath: "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      facts: DoctorLaunchd.plistFacts(fromPropertyList: Self.stdioPlist),
      kickstartTarget: "system/com.runnervm.runnerd",
      directoryExists: { _ in false })
    #expect(check.id == "launchd_stdio_dir")
    #expect(check.status == .fail)
    #expect(check.detail.contains("/Library/Application Support/RunnerVM/logs/runnerd"))
    #expect(check.detail.contains("mkdir -p"))
    #expect(check.detail.contains("launchctl kickstart -k system/com.runnervm.runnerd"))
  }

  @Test func anExistingStdioDirectoryPasses() {
    let check = DoctorLaunchd.stdioDirectoryCheck(
      plistPath: "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      facts: DoctorLaunchd.plistFacts(fromPropertyList: Self.stdioPlist),
      kickstartTarget: "system/com.runnervm.runnerd",
      directoryExists: { _ in true })
    #expect(check.status == .ok)
  }

  @Test func aPlistThatRedirectsNothingHasNoDirectoryToCheck() {
    let check = DoctorLaunchd.stdioDirectoryCheck(
      plistPath: "/tmp/x.plist",
      facts: DoctorLaunchd.PlistFacts(throttleInterval: 30),
      kickstartTarget: nil, directoryExists: { _ in false })
    #expect(check.status == .ok)
  }

  @Test func anUnreadablePlistWarnsRatherThanFails() {
    let check = DoctorLaunchd.stdioDirectoryCheck(
      plistPath: "/tmp/x.plist", facts: nil, kickstartTarget: nil,
      directoryExists: { _ in false })
    #expect(check.status == .warn)
    #expect(DoctorLaunchd.throttleCheck(plistPath: "/tmp/x.plist", facts: nil).status == .warn)
  }

  /// `skip`, not `warn`: a foreground host has no plist and nothing is wrong with that.
  @Test func noInstalledPlistSkipsBothPlistChecks() {
    #expect(
      DoctorLaunchd.stdioDirectoryCheck(
        plistPath: nil, facts: nil, kickstartTarget: nil, directoryExists: { _ in false }
      ).status == .skip)
    #expect(DoctorLaunchd.throttleCheck(plistPath: nil, facts: nil).status == .skip)
  }

  @Test func anOlderThrottleIntervalWarns() {
    let check = DoctorLaunchd.throttleCheck(
      plistPath: "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      facts: DoctorLaunchd.PlistFacts(throttleInterval: 5))
    #expect(check.id == "launchd_throttle")
    #expect(check.status == .warn)
    #expect(check.detail.contains("5s"))
    #expect(check.detail.contains("ThrottleInterval 30"))
  }

  /// No key at all is worse than an old one: launchd falls back to 10 s.
  @Test func aPlistWithoutAThrottleIntervalWarns() {
    let check = DoctorLaunchd.throttleCheck(
      plistPath: "/tmp/x.plist", facts: DoctorLaunchd.PlistFacts(standardOutPath: "/tmp/a.log"))
    #expect(check.status == .warn)
    #expect(check.detail.contains("no ThrottleInterval"))
  }

  @Test func theShippedThrottleIntervalPasses() {
    let check = DoctorLaunchd.throttleCheck(
      plistPath: "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      facts: DoctorLaunchd.plistFacts(fromPropertyList: Self.stdioPlist))
    #expect(check.status == .ok)
  }
}
