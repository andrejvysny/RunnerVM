import Foundation
import Testing

@testable import HostSetup

/// Rendering, linting, installing and loading the launchd job — and the socket wait that decides
/// whether the daemon actually came up.
@Suite struct LaunchdManagerTests {
  static let template = """
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0">
  <dict>
      <key>Label</key>
      <string>com.runnervm.runnerd</string>
      <key>ProgramArguments</key>
      <array>
          <string>__RUNNERD_PATH__</string>
          <string>--config</string>
          <string>__CONFIG_PATH__</string>
          <string>--state-dir</string>
          <string>__STATE_DIR__</string>
          <string>--socket-dir</string>
          <string>__RUNTIME_DIR__</string>
          <string>--log-level</string>
          <string>__LOG_LEVEL__</string>
      </array>
      <key>UserName</key>
      <string>__SERVICE_USER__</string>
      <key>GroupName</key>
      <string>__SERVICE_GROUP__</string>
      <key>StandardOutPath</key>
      <string>__LOG_PATH__</string>
  </dict>
  </plist>
  """

  static func spec(mode: ServiceDeploymentMode = .daemon, uid: Int? = nil) -> LaunchdJobSpec {
    LaunchdJobSpec(
      mode: mode, configPath: "/Library/Application Support/RunnerVM/config.yaml",
      stateDir: "/Library/Application Support/RunnerVM", runtimeDir: "/var/run/runnervm",
      serviceUID: uid)
  }

  /// A manager whose templates live in memory: `readFile` answers with the fixture, `fileExists`
  /// says the installed template directory has it.
  static func manager(
    runner: any CommandRunner,
    templateExistsIn: String = LaunchdManager.installedTemplateDirectory,
    socketAppearsAfter: Int = 0,
    clock: FakeClock = FakeClock()
  ) -> LaunchdManager {
    let probes = Probe(socketAppearsAfter: socketAppearsAfter, templateDirectory: templateExistsIn)
    return LaunchdManager(
      runner: runner,
      templateDirectories: [LaunchdManager.installedTemplateDirectory, "/repo/packaging/launchd"],
      readFile: { _ in template },
      writeTemporary: { _, name in "/tmp/staged/\(name)" },
      fileExists: { probes.exists($0) },
      sleep: { clock.advance(by: $0) },
      now: { clock.now() })
  }

  /// Counts socket probes so "the socket appears on the Nth poll" is expressible without a clock
  /// race. `@unchecked Sendable` for the same reason `FakeClock` is: one test drives it at a time.
  final class Probe: @unchecked Sendable {
    private let socketAppearsAfter: Int
    private let templateDirectory: String
    private var probes = 0

    init(socketAppearsAfter: Int, templateDirectory: String) {
      self.socketAppearsAfter = socketAppearsAfter
      self.templateDirectory = templateDirectory
    }

    func exists(_ path: String) -> Bool {
      guard path.hasSuffix(".sock") else { return path.hasPrefix(templateDirectory) }
      probes += 1
      return probes > socketAppearsAfter
    }
  }

  // MARK: - Render

  @Test func rendersEveryPlaceholderTheInstallScriptSubstitutes() throws {
    let rendered = try Self.manager(runner: RecordingCommandRunner()).render(Self.spec())
    #expect(!rendered.contains("__"))
    #expect(rendered.contains("<string>/usr/local/libexec/runnervm/runnerd</string>"))
    #expect(rendered.contains("<string>/Library/Application Support/RunnerVM/config.yaml</string>"))
    #expect(rendered.contains("<string>/var/run/runnervm</string>"))
    #expect(rendered.contains("<string>_runnervm</string>"))
    #expect(rendered.contains(
      "<string>/Library/Application Support/RunnerVM/logs/runnerd/stdio.log</string>"))
  }

  /// The repo checkout is the development fallback when the pkg's template directory is absent.
  @Test func fallsBackToTheRepoTemplateDirectory() throws {
    let manager = Self.manager(
      runner: RecordingCommandRunner(), templateExistsIn: "/repo/packaging/launchd")
    #expect(try manager.render(Self.spec()).contains("com.runnervm.runnerd"))
  }

  @Test func reportsEverySearchedDirectoryWhenNoTemplateIsFound() {
    let manager = Self.manager(runner: RecordingCommandRunner(), templateExistsIn: "/nowhere")
    #expect(throws: SetupError.self) { try manager.render(Self.spec()) }
    do {
      _ = try manager.render(Self.spec())
    } catch let error as SetupError {
      #expect(error.code == "SETUP_TEMPLATE_NOT_FOUND")
      #expect(error.message.contains("/repo/packaging/launchd"))
    } catch {
      Issue.record("expected SetupError")
    }
  }

  // MARK: - Install

  @Test func lintsBeforeInstallingAndBootsOutBeforeBootstrapping() async throws {
    let runner = RecordingCommandRunner()
    try await Self.manager(runner: runner).install(Self.spec())

    #expect(await runner.lines == [
      "/usr/bin/plutil -lint /tmp/staged/com.runnervm.runnerd.daemon.plist",
      "/usr/bin/install -m 0644 -o root -g wheel "
        + "/tmp/staged/com.runnervm.runnerd.daemon.plist "
        + "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      "/bin/launchctl bootout system/com.runnervm.runnerd",
      "/bin/launchctl bootstrap system "
        + "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist",
      "/bin/launchctl enable system/com.runnervm.runnerd",
    ])
  }

  /// "Was not loaded" and "was unloaded" are the same precondition, and only one of them exits
  /// zero, so a failing bootout must not abort the install.
  @Test func aFailingBootoutDoesNotStopTheInstall() async throws {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["bootout"], 3, "Could not find service"),
    ])
    let steps = try await Self.manager(runner: runner).install(Self.spec())
    #expect(steps.contains { $0.contains("bootstrapped") })
    #expect(await runner.lines.contains { $0.contains("bootstrap") })
  }

  @Test func aFailingLintAbortsBeforeAnythingIsInstalled() async {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["-lint"], 1, "Unexpected character at line 3"),
    ])
    await #expect(throws: SetupError.self) {
      try await Self.manager(runner: runner).install(Self.spec())
    }
    #expect(await !runner.lines.contains { $0.contains("/usr/bin/install") })
    #expect(await !runner.lines.contains { $0.contains("launchctl") })
  }

  @Test func theAgentVariantInstallsToLaunchAgentsInItsOwnGUIDomain() async throws {
    let runner = RecordingCommandRunner()
    try await Self.manager(runner: runner).install(Self.spec(mode: .agent, uid: 206))

    let lines = await runner.lines
    #expect(lines.contains { $0.contains("/Library/LaunchAgents/com.runnervm.runnerd.agent.plist") })
    #expect(lines.contains("/bin/launchctl bootstrap gui/206 "
      + "/Library/LaunchAgents/com.runnervm.runnerd.agent.plist"))
    #expect(lines.contains("/bin/launchctl enable gui/206/com.runnervm.runnerd"))
  }

  // MARK: - Socket wait

  @Test func returnsAsSoonAsTheSocketAppears() async throws {
    let manager = Self.manager(runner: RecordingCommandRunner(), socketAppearsAfter: 0)
    _ = try await manager.waitForSocket(at: "/var/run/runnervm/runnerd.sock")
  }

  @Test func keepsPollingUntilTheSocketShowsUp() async throws {
    let clock = FakeClock()
    let manager = Self.manager(
      runner: RecordingCommandRunner(), socketAppearsAfter: 6, clock: clock)
    let elapsed = try await manager.waitForSocket(at: "/var/run/runnervm/runnerd.sock")
    // Six 500 ms polls before the socket exists.
    #expect(elapsed.components.seconds == 3)
  }

  /// A daemon that never publishes its socket has to fail loudly, with the path and the budget,
  /// rather than hang the installer.
  @Test func timesOutWithThePathAndTheBudget() async {
    let clock = FakeClock()
    let manager = Self.manager(
      runner: RecordingCommandRunner(), socketAppearsAfter: .max, clock: clock)
    do {
      _ = try await manager.waitForSocket(
        at: "/var/run/runnervm/runnerd.sock", timeout: .seconds(30))
      Issue.record("expected a timeout")
    } catch let error as SetupError {
      #expect(error.code == "SETUP_SOCKET_NEVER_APPEARED")
      #expect(error.message.contains("/var/run/runnervm/runnerd.sock"))
      #expect(error.message.contains("30s"))
    } catch {
      Issue.record("expected SetupError, got \(error)")
    }
  }

  // MARK: - Shipped templates

  /// The real templates in `packaging/launchd` must carry exactly the placeholders this renderer
  /// substitutes — a template gaining a new one would otherwise ship a literal `__TOKEN__` into
  /// `/Library/LaunchDaemons`.
  @Test(arguments: ServiceDeploymentMode.allCases)
  func theShippedTemplatesContainNoUnknownPlaceholders(_ mode: ServiceDeploymentMode) throws {
    let path = "\(Self.repoRoot)/packaging/launchd/\(mode.plistFileName)"
    guard FileManager.default.fileExists(atPath: path) else { return }  // not a checkout
    let template = try String(contentsOfFile: path, encoding: .utf8)
    let rendered = LaunchdManager.substitute(template, with: Self.spec().substitutions)
    #expect(!rendered.contains("__"), "unsubstituted placeholder in \(mode.plistFileName)")
  }

  /// `Tests/HostSetupTests/LaunchdManagerTests.swift` -> repo root.
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .path(percentEncoded: false)
}
