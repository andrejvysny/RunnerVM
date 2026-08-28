import Foundation

/// How `runnerd` is started at boot.
public enum ServiceDeploymentMode: String, Sendable, Codable, CaseIterable {
  /// LaunchDaemon under the service account: no GUI session, comes back after a reboot on its own.
  /// The recommended production default.
  case daemon
  /// LaunchAgent in a GUI session. Only restarts once its account has logged in, so reboot
  /// recovery depends on autologin.
  case agent

  public var plistFileName: String { "com.runnervm.runnerd.\(rawValue).plist" }

  public var installDirectory: String {
    switch self {
    case .daemon: "/Library/LaunchDaemons"
    case .agent: "/Library/LaunchAgents"
    }
  }

  public var installedPath: String { "\(installDirectory)/\(plistFileName)" }
}

/// Everything the plist templates' `__PLACEHOLDER__` tokens stand for.
public struct LaunchdJobSpec: Sendable, Hashable {
  public var mode: ServiceDeploymentMode
  public var runnerdPath: String
  public var configPath: String
  public var stateDir: String
  public var runtimeDir: String
  public var logLevel: String
  public var serviceUser: String
  public var serviceGroup: String
  /// The service account's uid, needed for a LaunchAgent's `gui/<uid>` domain target.
  public var serviceUID: Int?

  public init(
    mode: ServiceDeploymentMode,
    runnerdPath: String = "/usr/local/libexec/runnervm/runnerd",
    configPath: String,
    stateDir: String,
    runtimeDir: String,
    logLevel: String = "info",
    serviceUser: String = "_runnervm",
    serviceGroup: String = "_runnervm",
    serviceUID: Int? = nil
  ) {
    self.mode = mode
    self.runnerdPath = runnerdPath
    self.configPath = configPath
    self.stateDir = stateDir
    self.runtimeDir = runtimeDir
    self.logLevel = logLevel
    self.serviceUser = serviceUser
    self.serviceGroup = serviceGroup
    self.serviceUID = serviceUID
  }

  /// `<state-dir>/logs/runnerd/stdio.log`, matching the templates' `StandardOutPath`.
  public var stdioLogPath: String { "\(stateDir)/logs/runnerd/stdio.log" }

  var substitutions: [String: String] {
    [
      "__RUNNERD_PATH__": runnerdPath,
      "__CONFIG_PATH__": configPath,
      "__STATE_DIR__": stateDir,
      "__RUNTIME_DIR__": runtimeDir,
      "__LOG_PATH__": stdioLogPath,
      "__LOG_LEVEL__": logLevel,
      "__SERVICE_USER__": serviceUser,
      "__SERVICE_GROUP__": serviceGroup,
    ]
  }

  /// `system` for a LaunchDaemon, `gui/<uid>` for a LaunchAgent — the domain `launchctl bootstrap`
  /// and `launchctl enable` are addressed to.
  public var domainTarget: String {
    switch mode {
    case .daemon: "system"
    case .agent: "gui/\(serviceUID ?? Int(getuid()))"
    }
  }
}

/// Renders, lints, installs and loads the launchd job, then waits for the daemon to publish its
/// socket. The same render/install sequence `scripts/install.sh` section 7 performs, in Swift and
/// through `CommandRunner` so it is testable and interceptable by `--dry-run`.
public struct LaunchdManager: Sendable {
  public static let label = "com.runnervm.runnerd"
  /// Where the pkg puts the templates; the repo checkout is the development fallback.
  public static let installedTemplateDirectory = "/usr/local/share/runnervm/launchd"

  static let plutil = "/usr/bin/plutil"
  static let install = "/usr/bin/install"
  static let launchctl = "/bin/launchctl"

  private let runner: any CommandRunner
  private let templateDirectories: [String]
  private let readFile: @Sendable (String) throws -> String
  private let writeTemporary: @Sendable (String, String) throws -> String
  private let fileExists: @Sendable (String) -> Bool
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date

  public init(
    runner: any CommandRunner = DefaultCommandRunner(),
    templateDirectories: [String] = LaunchdManager.defaultTemplateDirectories(),
    readFile: @escaping @Sendable (String) throws -> String = {
      try String(contentsOfFile: $0, encoding: .utf8)
    },
    writeTemporary: @escaping @Sendable (String, String) throws -> String
      = LaunchdManager.writeTemporaryFile,
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.runner = runner
    self.templateDirectories = templateDirectories
    self.readFile = readFile
    self.writeTemporary = writeTemporary
    self.fileExists = fileExists
    self.sleep = sleep
    self.now = now
  }

  /// `/usr/local/share/runnervm/launchd` first, then `packaging/launchd` relative to the running
  /// binary's repo checkout so a `swift build` copy of `runnerctl` works without an install.
  public static func defaultTemplateDirectories() -> [String] {
    var directories = [installedTemplateDirectory]
    // .build/debug/runnerctl -> repo root is three levels up.
    let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
      .resolvingSymlinksInPath()
    let repoRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    directories.append(repoRoot.appending(path: "packaging/launchd").path(percentEncoded: false))
    return directories
  }

  // MARK: - Render

  /// The template with every `__PLACEHOLDER__` replaced, exactly as `install.sh`'s `render_plist`
  /// `sed` sequence produces it.
  public func render(_ spec: LaunchdJobSpec) throws -> String {
    let template = try loadTemplate(named: spec.mode.plistFileName)
    return Self.substitute(template, with: spec.substitutions)
  }

  public static func substitute(_ template: String, with values: [String: String]) -> String {
    values.reduce(template) { text, entry in
      text.replacingOccurrences(of: entry.key, with: entry.value)
    }
  }

  private func loadTemplate(named name: String) throws -> String {
    for directory in templateDirectories {
      let path = "\(directory)/\(name)"
      guard fileExists(path), let text = try? readFile(path) else { continue }
      return text
    }
    throw SetupError.templateNotFound(name: name, searched: templateDirectories)
  }

  // MARK: - Install

  /// Renders, lints, installs root:wheel 0644, then reloads the job. `bootout` runs first and its
  /// failure is ignored on purpose: "was not loaded" and "was unloaded" are the same
  /// precondition, and only one of them exits zero.
  ///
  /// Returns the human-readable steps performed, in order.
  @discardableResult
  public func install(_ spec: LaunchdJobSpec) async throws -> [String] {
    var steps: [String] = []
    let rendered = try render(spec)
    let staged = try writeTemporary(rendered, spec.mode.plistFileName)
    steps.append("rendered \(spec.mode.plistFileName)")

    try await runner.runChecked([Self.plutil, "-lint", staged])
    steps.append("plutil -lint passed")

    try await runner.runChecked([
      Self.install, "-m", "0644", "-o", "root", "-g", "wheel", staged, spec.mode.installedPath,
    ])
    steps.append("installed \(spec.mode.installedPath)")

    // Ignored by design: bootout exits non-zero when nothing was loaded.
    _ = try? await runner.run([Self.launchctl, "bootout", "\(spec.domainTarget)/\(Self.label)"])
    try await runner.runChecked([
      Self.launchctl, "bootstrap", spec.domainTarget, spec.mode.installedPath,
    ])
    try await runner.runChecked([
      Self.launchctl, "enable", "\(spec.domainTarget)/\(Self.label)",
    ])
    steps.append("bootstrapped into \(spec.domainTarget)")
    return steps
  }

  /// Polls for the daemon's socket. A launchd job that took is not the same fact as a daemon that
  /// finished starting; the socket is the one that matters to everything `setup` does next.
  @discardableResult
  public func waitForSocket(at path: String, timeout: Duration = .seconds(30)) async throws -> Duration {
    let started = now()
    let seconds = Self.seconds(timeout)
    let deadline = started.addingTimeInterval(seconds)
    while true {
      if fileExists(path) {
        return .seconds(Int(now().timeIntervalSince(started)))
      }
      guard now() < deadline else {
        throw SetupError.socketNeverAppeared(path: path, seconds: Int(seconds))
      }
      try await sleep(.milliseconds(500))
    }
  }

  static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  /// The rendered plist lands in the process's temp directory before `install(1)` copies it into
  /// place. A temp file is not a host mutation, so `--dry-run` still lints the real document.
  public static func writeTemporaryFile(_ contents: String, _ name: String) throws -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "runnervm-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let path = directory.appending(path: name)
    try contents.write(to: path, atomically: true, encoding: .utf8)
    return path.path(percentEncoded: false)
  }
}
