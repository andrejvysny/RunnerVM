import DaemonAPI
import Foundation
import GuestControl
import RunnerCore
import Testing

@testable import HostSetup

@Suite struct SmokeTestTests {
  private static func paths(root: URL) -> RunnerPaths {
    RunnerPaths(rootDir: root, runtimeDir: root.appending(path: "run"))
  }

  private static func tempRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "rvm-smoketest-\(UUID().uuidString)")
  }

  private func run(
    _ daemon: FakeSmokeTestDaemon, options: SmokeTestOptions, root: URL, clock: FakeClock = FakeClock(),
    sshPort: UInt16 = 22
  ) async -> SmokeTestReport {
    let smokeTest = SmokeTest(
      client: daemon, paths: Self.paths(root: root), now: { clock.now() },
      sleep: { clock.advance(by: $0) }, sshPort: sshPort)
    return await smokeTest.run(options)
  }

  @Test func happyPathLinux() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(
      bootStates: ["planned", "startingVM", "idle"],
      execResult: .value(("Linux runnervm 6.8.0", 0)))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", macOS: false), root: root)

    #expect(report.passed)
    #expect(report.instanceId != nil)
    let names = Set(report.checks.map(\.name))
    #expect(names == [
      "instance.create", "instance.boot", "guest.exec", "instance.delete", "leak.instanceState",
      "leak.instanceDirectory", "leak.vmworkerProcess",
    ])
    #expect(await daemon.deleteCallCount == 1)
  }

  @Test func happyPathMacOS() async throws {
    let root = Self.tempRoot()
    let (listenerFD, closedPort) = try PortProbeTests.bindListener()
    close(listenerFD)  // free the port; nothing is listening any more
    let daemon = FakeSmokeTestDaemon(
      execResult: .value(("15.6", 0)),
      selfTestResult: .value(SelfTestResult(checks: [SelfTestCheck(name: "keychain.create", ok: true)])),
      sshInfoResult: .value(InstanceSSHInfo(ipAddresses: ["127.0.0.1"], user: "runner", sshEnabled: true)))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "rvm-macos-26", macOS: true), root: root,
      sshPort: closedPort)

    #expect(report.passed)
    let sshCheck = report.checks.first { $0.name == "guest.sshClosed" }
    #expect(sshCheck?.ok == true)
    let selfTestCheck = report.checks.first { $0.name == "guest.selfTest" }
    #expect(selfTestCheck?.ok == true)
  }

  @Test func bootTimeoutFails() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(bootStates: ["waitingForAgent"])
    let clock = FakeClock()
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", bootTimeout: .seconds(3), macOS: false),
      root: root, clock: clock)

    #expect(!report.passed)
    let boot = report.checks.first { $0.name == "instance.boot" }
    #expect(boot?.ok == false)
    #expect(boot?.detail.contains("waitingForAgent") == true)
    // guest.exec never ran: nothing to check without a booted guest.
    #expect(!report.checks.contains { $0.name == "guest.exec" })
    // Teardown and the leak checks are always attempted, even after a boot timeout.
    #expect(await daemon.deleteCallCount == 1)
    #expect(report.checks.contains { $0.name == "instance.delete" })
  }

  @Test func instanceLandsFailed() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(bootStates: ["failed"])
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", macOS: false), root: root)

    #expect(!report.passed)
    let boot = report.checks.first { $0.name == "instance.boot" }
    #expect(boot?.ok == false)
    #expect(boot?.detail.contains("failed") == true)
    #expect(await daemon.deleteCallCount == 1)
  }

  @Test func execNonZeroFails() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(execResult: .value(("boom", 1)))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", macOS: false), root: root)

    #expect(!report.passed)
    let exec = report.checks.first { $0.name == "guest.exec" }
    #expect(exec?.ok == false)
    #expect(exec?.detail.contains("exit 1") == true)
    // Teardown always attempted, even after a failed exec.
    #expect(await daemon.deleteCallCount == 1)
  }

  @Test func macOSSelfTestFailureFails() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(
      execResult: .value(("15.6", 0)),
      selfTestResult: .value(SelfTestResult(checks: [
        SelfTestCheck(name: "keychain.create", ok: true),
        SelfTestCheck(name: "codesign.sign", ok: false, detail: "no identity found"),
      ])))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "rvm-macos-26", macOS: true), root: root)

    #expect(!report.passed)
    let selfTest = report.checks.first { $0.name == "guest.selfTest" }
    #expect(selfTest?.ok == false)
    #expect(selfTest?.detail == "codesign.sign: no identity found")
    // ssh-closed still runs independently (no IP reported here, so it is a vacuous pass).
    #expect(report.checks.first { $0.name == "guest.sshClosed" }?.ok == true)
  }

  @Test func sshPortOpenFails() async throws {
    let root = Self.tempRoot()
    let (listenerFD, openPort) = try PortProbeTests.bindListener()
    defer { close(listenerFD) }
    let daemon = FakeSmokeTestDaemon(
      execResult: .value(("15.6", 0)),
      sshInfoResult: .value(InstanceSSHInfo(ipAddresses: ["127.0.0.1"], user: "runner", sshEnabled: true)))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "rvm-macos-26", macOS: true), root: root,
      sshPort: openPort)

    #expect(!report.passed)
    let ssh = report.checks.first { $0.name == "guest.sshClosed" }
    #expect(ssh?.ok == false)
    #expect(ssh?.detail.contains("accepted a connection") == true)
  }

  @Test func leakCheckFailsWhenInstanceDirectoryStillExists() async throws {
    let root = Self.tempRoot()
    let paths = Self.paths(root: root)
    let stub = InstanceInfoDTO.stub()
    try FileManager.default.createDirectory(
      at: paths.instanceDir(InstanceID(rawValue: stub.id)), withIntermediateDirectories: true)

    let daemon = FakeSmokeTestDaemon()
    let smokeTest = SmokeTest(client: daemon, paths: paths, now: { Date() }, sleep: { _ in }, sshPort: 22)
    let report = await smokeTest.run(SmokeTestOptions(profile: "ubuntu-24", macOS: false))

    #expect(!report.passed)
    let leak = report.checks.first { $0.name == "leak.instanceDirectory" }
    #expect(leak?.ok == false)
  }

  /// Teardown and the leak checks run to completion after a mid-flow failure (exec, here) -- not
  /// just "delete was called", but the whole leak-check trio a passing run also gets.
  @Test func teardownAlwaysAttemptedAfterAFailure() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(execResult: .value(("boom", 1)))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", macOS: false), root: root)

    #expect(!report.passed)
    #expect(await daemon.deleteCallCount == 1)
    #expect(report.checks.first { $0.name == "instance.delete" }?.ok == true)
    #expect(report.checks.first { $0.name == "leak.instanceState" }?.ok == true)
    #expect(report.checks.first { $0.name == "leak.instanceDirectory" }?.ok == true)
    #expect(report.checks.first { $0.name == "leak.vmworkerProcess" }?.ok == true)
  }

  /// The one case where teardown correctly never runs: nothing was ever created.
  @Test func createFailureSkipsTeardown() async {
    let root = Self.tempRoot()
    let daemon = FakeSmokeTestDaemon(createResult: .failure(TestError("refused")))
    let report = await run(
      daemon, options: SmokeTestOptions(profile: "ubuntu-24", macOS: false), root: root)

    #expect(!report.passed)
    #expect(report.instanceId == nil)
    #expect(await daemon.deleteCallCount == 0)
    #expect(report.checks.map(\.name) == ["instance.create"])
  }
}
