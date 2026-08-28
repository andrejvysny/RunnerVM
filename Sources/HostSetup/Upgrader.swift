import DaemonAPI
import Foundation
import RunnerCore

/// `sudo runnerctl upgrade` — manual-only software upgrade, implementing
/// `docs/design/distribution.md` "Upgrade policy" and "Failure semantics".
///
/// The whole point of the ordering below is that everything which can fail without consequence
/// happens first: the manifest, the download and both checksum comparisons run before a single
/// host-visible change, so a bad release, a truncated download or an unreachable network leaves the
/// host exactly as it was. Only once the bytes on disk are proven does the drain → bootout →
/// `installer` → bootstrap sequence start.
///
/// Every host mutation goes through `CommandRunner`, the same seam `HostInstaller` uses, so the
/// exact command sequence is a test assertion rather than something that has to be observed on a
/// real Mac.
public struct Upgrader: Sendable {
  /// Everything the upgrader needs from the outside world, so the whole thing is testable.
  public struct Dependencies: Sendable {
    public var runner: any CommandRunner
    public var io: any SetupIO
    /// Only `waitForSocket` is used: an upgrade deliberately does not re-render the plist. The pkg
    /// ships new templates, but the installed document was rendered against this host's paths and
    /// may carry operator edits, so it is reloaded, never regenerated.
    public var launchd: LaunchdManager
    public var connect: @Sendable (String) async throws -> any UpgradeDaemon
    public var writeTemporary: @Sendable (String, String) throws -> String
    public var readFile: @Sendable (String) throws -> String
    public var fileExists: @Sendable (String) -> Bool
    public var now: @Sendable () -> Date

    public init(
      runner: any CommandRunner,
      io: any SetupIO,
      launchd: LaunchdManager,
      connect: @escaping @Sendable (String) async throws -> any UpgradeDaemon,
      writeTemporary: @escaping @Sendable (String, String) throws -> String
        = LaunchdManager.writeTemporaryFile,
      readFile: @escaping @Sendable (String) throws -> String = {
        try String(contentsOfFile: $0, encoding: .utf8)
      },
      fileExists: @escaping @Sendable (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
      },
      now: @escaping @Sendable () -> Date = { Date() }
    ) {
      self.runner = runner
      self.io = io
      self.launchd = launchd
      self.connect = connect
      self.writeTemporary = writeTemporary
      self.readFile = readFile
      self.fileExists = fileExists
      self.now = now
    }
  }

  /// What the flags decided. Nothing here is discovered; `UpgradeCommand` resolves every value.
  public struct Options: Sendable {
    public var stateDir: String
    public var runtimeDir: String
    public var mode: ServiceDeploymentMode
    /// A LaunchAgent's `gui/<uid>` domain. Ignored for a LaunchDaemon.
    public var serviceUID: Int?
    /// `--version vX`; `nil` means `/releases/latest/download/`. Also the flag that makes a
    /// same-version or older release install anyway: asking for a tag by name is an instruction.
    public var requestedVersion: String?
    /// `RUNNERVM_PKG_URL`, the same mirror/`file://` seam `scripts/bootstrap.sh` exposes.
    public var packageURLOverride: String?
    public var drainTimeout: Duration
    public var socketTimeout: Duration
    public var assumeYes: Bool
    /// `RUNNERVM_ALLOW_UNSIGNED=1`. Suppresses the unsigned *prompt*, never the warning.
    public var allowUnsigned: Bool
    /// Read once, here, rather than inside the manifest check: the platform gate is a decision
    /// about this host, and a decision made from injected facts is one a test can exercise.
    public var hostArchitecture: String
    public var hostMacOSMajor: Int

    public init(
      stateDir: String = SetupDefaults.stateDir,
      runtimeDir: String = SetupDefaults.runtimeDir,
      mode: ServiceDeploymentMode = .daemon,
      serviceUID: Int? = nil,
      requestedVersion: String? = nil,
      packageURLOverride: String? = nil,
      drainTimeout: Duration = .seconds(1_800),
      socketTimeout: Duration = .seconds(60),
      assumeYes: Bool = false,
      allowUnsigned: Bool = false,
      hostArchitecture: String = ReleaseManifest.hostArchitecture,
      hostMacOSMajor: Int = ReleaseManifest.hostMacOSMajor
    ) {
      self.hostArchitecture = hostArchitecture
      self.hostMacOSMajor = hostMacOSMajor
      self.stateDir = stateDir
      self.runtimeDir = runtimeDir
      self.mode = mode
      self.serviceUID = serviceUID
      self.requestedVersion = requestedVersion
      self.packageURLOverride = packageURLOverride
      self.drainTimeout = drainTimeout
      self.socketTimeout = socketTimeout
      self.assumeYes = assumeYes
      self.allowUnsigned = allowUnsigned
    }

    public var source: ReleaseSource {
      ReleaseSource.resolve(version: requestedVersion, overrideURL: packageURLOverride)
    }
  }

  static let curl = "/usr/bin/curl"
  static let shasum = "/usr/bin/shasum"
  static let sqlite3 = "/usr/bin/sqlite3"
  static let installer = "/usr/sbin/installer"
  static let launchctl = "/bin/launchctl"
  static let mkdir = "/bin/mkdir"
  static let chmod = "/bin/chmod"
  static let chown = "/usr/sbin/chown"
  static let install = "/usr/bin/install"
  static let cp = "/bin/cp"
  static let rm = "/bin/rm"
  static let stat = "/usr/bin/stat"
  static let sh = "/bin/sh"

  let deps: Dependencies
  let options: Options

  public init(_ deps: Dependencies, options: Options = Options()) {
    self.deps = deps
    self.options = options
  }

  // MARK: - Paths

  var upgradesDir: String { "\(options.stateDir)/upgrades" }
  func cacheDir(_ version: String) -> String { "\(upgradesDir)/\(version)" }
  var configPath: String { "\(options.stateDir)/config.yaml" }
  /// `RunnerPaths.databaseURL`'s production layout, spelled from the state root the flags gave.
  var databasePath: String { "\(options.stateDir)/state/runnerd.sqlite3" }
  var socketPath: String { "\(options.runtimeDir)/runnerd.sock" }
  var plistPath: String { options.mode.installedPath }

  /// `system` for a LaunchDaemon, `gui/<uid>` for a LaunchAgent — matching `LaunchdJobSpec`.
  var domainTarget: String {
    switch options.mode {
    case .daemon: "system"
    case .agent: "gui/\(options.serviceUID ?? Int(getuid()))"
    }
  }

  // MARK: - --check

  /// Fetches and compares, and touches nothing. The only method that is safe without root.
  public func check() async throws -> UpgradeCheck {
    let (manifest, _) = try await fetchManifest()
    return UpgradeCheck(current: RunnerVMVersion.current, manifest: manifest)
  }

  private func fetchManifest() async throws -> (ReleaseManifest, String) {
    let url = options.source.manifestURL
    let result: CommandResult
    do {
      result = try await deps.runner.run([Self.curl, "-fsSL", url])
    } catch {
      throw UpgradeError.manifestUnreachable(url: url, detail: Self.describe(error))
    }
    guard result.isSuccess else {
      let detail = result.failureDetail.isEmpty
        ? "curl exited \(result.exitCode)" : result.failureDetail
      throw UpgradeError.manifestUnreachable(url: url, detail: detail)
    }
    return (try ReleaseManifest.decode(result.stdout), result.stdout)
  }

  // MARK: - Entry point

  public func run() async -> UpgradeReport {
    var report = UpgradeReport(fromVersion: RunnerVMVersion.current)
    deps.io.heading("Upgrading RunnerVM")

    guard let (manifest, manifestText) = await manifestStep(&report) else { return finish(report) }
    guard await downloadStep(manifest, manifestText: manifestText, report: &report),
          await checksumStep(manifest, report: &report),
          await rollbackMaterialStep(report: &report),
          confirmStep(manifest, report: &report),
          await backupStep(manifest, report: &report),
          await drainStep(report: &report),
          await stopStep(report: &report),
          await installStep(manifest, report: &report),
          await startStep(report: &report)
    else { return finish(report) }

    await schemaStep(&report)
    return finish(report)
  }

  // MARK: - Steps that cannot touch the host

  /// `nil` means either the manifest could not be used, or there is nothing to do — both of which
  /// end the run, which is why the caller does not distinguish them. The raw document travels with
  /// the parsed one because it is cached verbatim next to the pkg, so an upgrade's cache directory
  /// and a first install's are the same shape.
  private func manifestStep(
    _ report: inout UpgradeReport
  ) async -> (ReleaseManifest, String)? {
    do {
      let (manifest, text) = try await fetchManifest()
      try manifest.validatePlatform(
        architecture: options.hostArchitecture, macOSMajor: options.hostMacOSMajor)
      report.toVersion = manifest.version
      let verdict = UpgradeCheck(current: report.fromVersion, manifest: manifest)
      report.record(UpgradeReport.Name.manifest, true, verdict.summary)
      guard verdict.upgradeAvailable || options.requestedVersion != nil else {
        deps.io.say("Nothing to do: \(verdict.summary).")
        deps.io.say("Pass --version v<x.y.z> to install a specific release anyway.")
        return nil
      }
      return (manifest, text)
    } catch {
      report.record(UpgradeReport.Name.manifest, false, Self.describe(error))
      return nil
    }
  }

  private func downloadStep(
    _ manifest: ReleaseManifest, manifestText: String, report: inout UpgradeReport
  ) async -> Bool {
    let directory = cacheDir(manifest.version)
    let package = "\(directory)/\(manifest.package)"
    do {
      // The layout `scripts/bootstrap.sh`'s cache_release writes, verbatim: an upgrade's cache and
      // a first install's cache have to be interchangeable, because either can be the "previous
      // pkg" a later rollback reinstalls.
      try await deps.runner.runChecked([Self.mkdir, "-p", directory])
      try await deps.runner.runChecked([Self.chmod, "0755", upgradesDir])
      try await deps.runner.runChecked([Self.chmod, "0755", directory])
      deps.io.say("downloading \(manifest.package) \(manifest.version) …")
      try await deps.runner.runChecked([
        Self.curl, "-fsSL", options.source.assetURL(manifest.package), "-o", package,
      ])
      try await deps.runner.runChecked([
        Self.curl, "-fsSL", options.source.assetURL("\(manifest.package).sha256"), "-o",
        "\(package).sha256",
      ])
      let staged = try deps.writeTemporary(manifestText, ReleaseSource.manifestName)
      try await deps.runner.runChecked([
        Self.install, "-m", "0644", staged, "\(directory)/\(ReleaseSource.manifestName)",
      ])
      report.packagePath = package
      report.record(UpgradeReport.Name.download, true, package)
      return true
    } catch {
      report.record(UpgradeReport.Name.download, false, Self.describe(error))
      deps.io.say("Nothing was installed; this host is exactly as it was.")
      return false
    }
  }

  /// Two independent sources have to agree before `installer` is ever reached: the detached
  /// `.sha256` file and the manifest's own `sha256` field.
  private func checksumStep(
    _ manifest: ReleaseManifest, report: inout UpgradeReport
  ) async -> Bool {
    let directory = cacheDir(manifest.version)
    do {
      // `shasum -c` resolves the path inside the checksum file relative to the working directory,
      // and `CommandRunner` has no cwd — so the `cd` is part of the command, the same
      // `(cd … && shasum -a 256 -c …)` bootstrap.sh runs.
      try await deps.runner.runChecked([
        Self.sh, "-c",
        "cd \(Self.quote(directory)) && \(Self.shasum) -a 256 -c "
          + Self.quote("\(manifest.package).sha256"),
      ])
      let hashed = try await deps.runner.runChecked([
        Self.shasum, "-a", "256", "\(directory)/\(manifest.package)",
      ])
      let actual = hashed.trimmedStdout.split(separator: " ").first.map(String.init) ?? ""
      guard actual.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
        throw UpgradeError.checksumMismatch(
          detail: "\(manifest.package) hashes to \(actual), release-manifest.json says "
            + manifest.sha256)
      }
      report.record(
        UpgradeReport.Name.checksum, true,
        "matches \(manifest.package).sha256 and release-manifest.json")
      return true
    } catch {
      report.record(UpgradeReport.Name.checksum, false, Self.describe(error))
      deps.io.say("Nothing was installed; this host is exactly as it was.")
      return false
    }
  }

  /// Checked *before* the upgrade starts, not after it fails: a rollback reinstalls the pkg for the
  /// version being replaced, and discovering it is missing while the daemon is booted out is too
  /// late to be useful.
  private func rollbackMaterialStep(report: inout UpgradeReport) async -> Bool {
    if let previous = previousPackagePath() {
      report.previousPackagePath = previous
      report.record(UpgradeReport.Name.rollbackMaterial, true, previous)
      return true
    }
    let directory = cacheDir(report.fromVersion)
    deps.io.say("")
    deps.io.say("No cached package for the installed version \(report.fromVersion) was found in")
    deps.io.say("\(directory). If the new version fails its health check, RunnerVM cannot")
    deps.io.say("reinstall the old one for you — the rollback would be a manual download.")
    guard confirm("Continue without a rollback package?", default: false) else {
      report.record(
        UpgradeReport.Name.rollbackMaterial, false,
        "declined: no cached pkg for \(report.fromVersion)")
      return false
    }
    report.record(
      UpgradeReport.Name.rollbackMaterial, true,
      "absent for \(report.fromVersion); rollback would be manual")
    return true
  }

  /// The cached pkg for the *installed* version. Its file name comes from that release's own
  /// manifest when one was cached, because the asset name is not guaranteed to be stable forever.
  func previousPackagePath() -> String? {
    let directory = cacheDir(RunnerVMVersion.current)
    guard let name = cachedPackageName(in: directory) else { return nil }
    let path = "\(directory)/\(name)"
    return deps.fileExists(path) ? path : nil
  }

  private func cachedPackageName(in directory: String) -> String? {
    guard let text = try? deps.readFile("\(directory)/\(ReleaseSource.manifestName)"),
          let manifest = try? ReleaseManifest.decode(text)
    else { return nil }
    return manifest.package
  }

  /// The unsigned warning and the last chance to stop, both before anything is drained.
  private func confirmStep(_ manifest: ReleaseManifest, report: inout UpgradeReport) -> Bool {
    var accepted: [String] = []
    if !manifest.signed {
      printUnsignedWarning(manifest)
      if options.allowUnsigned || options.assumeYes {
        accepted.append("unsigned package accepted")
        deps.io.say(options.allowUnsigned
          ? "RUNNERVM_ALLOW_UNSIGNED=1: continuing without a prompt."
          : "--yes: continuing without a prompt.")
      } else if deps.io.confirm("Install this unsigned package?", default: false) {
        accepted.append("unsigned package confirmed")
      } else {
        report.record(UpgradeReport.Name.confirmation, false, "declined: unsigned package")
        deps.io.say("Nothing was installed; this host is exactly as it was.")
        return false
      }
    }
    let prompt = "Drain this host and install \(manifest.version)?"
    guard confirm(prompt, default: false) else {
      report.record(UpgradeReport.Name.confirmation, false, "declined before draining")
      deps.io.say("Nothing was installed; this host is exactly as it was.")
      return false
    }
    accepted.append("upgrade confirmed")
    report.record(UpgradeReport.Name.confirmation, true, accepted.joined(separator: ", "))
    return true
  }

  private func printUnsignedWarning(_ manifest: ReleaseManifest) {
    let io = deps.io
    io.heading("WARNING: RunnerVM \(manifest.version) is UNSIGNED")
    io.say("This package is not signed with an Apple Developer ID and is not notarized.")
    io.say("")
    io.say("Its sha256 (\(manifest.sha256)) has been verified against")
    io.say("release-manifest.json. That protects the download against corruption and tampering")
    io.say("in transit only; it does not prove who built the package, because anyone who can")
    io.say("edit the release can regenerate a matching checksum. Verifying publisher identity")
    io.say("requires code signing, which this phase does not yet provide.")
    io.say("")
  }

  // MARK: - Steps that change the host

  /// `config.yaml`, a consistent `sqlite3 .backup` copy, and the two version numbers plus the
  /// schema the old binaries were running against — everything a rollback or a manual restore
  /// needs, in one dated directory.
  private func backupStep(
    _ manifest: ReleaseManifest, report: inout UpgradeReport
  ) async -> Bool {
    let directory = "\(upgradesDir)/backup-\(Self.timestamp(deps.now()))"
    do {
      try await deps.runner.runChecked([Self.mkdir, "-p", directory])
      try await deps.runner.runChecked([Self.chmod, "0700", directory])
      // Captured before the swap: restoring as root would leave files the service account cannot
      // write, and the daemon would come back up unable to open its own database.
      if let owner = try? await deps.runner.run([Self.stat, "-f", "%Su:%Sg", databasePath]),
         owner.isSuccess, !owner.trimmedStdout.isEmpty {
        report.stateOwner = owner.trimmedStdout
      }
      if deps.fileExists(configPath) {
        try await deps.runner.runChecked([Self.cp, "-p", configPath, "\(directory)/config.yaml"])
      }
      try await deps.runner.runChecked([
        Self.sqlite3, databasePath, ".backup '\(directory)/runnerd.sqlite3'",
      ])
      report.schemaBefore = await schemaVersion()
      let staged = try deps.writeTemporary(
        Self.versionsJSON(
          from: report.fromVersion, to: manifest.version, schemaBefore: report.schemaBefore),
        "versions.json")
      try await deps.runner.runChecked([
        Self.install, "-m", "0600", staged, "\(directory)/versions.json",
      ])
      report.backupDirectory = directory
      report.record(UpgradeReport.Name.backup, true, directory)
      return true
    } catch {
      report.record(UpgradeReport.Name.backup, false, Self.describe(error))
      deps.io.say("Nothing was installed; this host is exactly as it was.")
      return false
    }
  }

  /// A daemon that is not running has nothing to drain, which is a legitimate state (a crashed
  /// daemon is exactly when an operator upgrades) — but it is not the state the operator asked
  /// about, so it takes an explicit confirmation rather than being assumed.
  private func drainStep(report: inout UpgradeReport) async -> Bool {
    let daemon: any UpgradeDaemon
    do {
      daemon = try await deps.connect(socketPath)
    } catch {
      deps.io.say("")
      deps.io.say("The daemon is not reachable at \(socketPath), so there is nothing to drain.")
      guard confirm("Install over a daemon that is not running?", default: false) else {
        report.record(UpgradeReport.Name.drain, false, "declined: daemon unreachable")
        return false
      }
      report.record(
        UpgradeReport.Name.drain, true, "skipped: daemon unreachable, nothing to drain")
      return true
    }
    let seconds = Int(Self.seconds(options.drainTimeout))
    do {
      deps.io.say("draining (up to \(seconds)s) …")
      let response = try await daemon.systemDrain(
        wait: true, timeoutMs: Int64(seconds) * 1_000)
      guard response.drained else {
        report.record(
          UpgradeReport.Name.drain, false,
          "\(response.activeSessions) job(s) still running after \(seconds)s")
        _ = try? await daemon.systemResume()
        deps.io.say("Nothing was installed; the host has been returned to normal.")
        return false
      }
      report.record(UpgradeReport.Name.drain, true, "drained; \(response.activeSessions) active")
      return true
    } catch {
      report.record(UpgradeReport.Name.drain, false, Self.describe(error))
      return false
    }
  }

  /// `bootout`'s failure is ignored on purpose: "was not loaded" and "was unloaded" are the same
  /// precondition, and only one of them exits zero.
  private func stopStep(report: inout UpgradeReport) async -> Bool {
    _ = try? await deps.runner.run([
      Self.launchctl, "bootout", "\(domainTarget)/\(LaunchdManager.label)",
    ])
    report.record(UpgradeReport.Name.stop, true, "\(domainTarget)/\(LaunchdManager.label)")
    return true
  }

  private func installStep(
    _ manifest: ReleaseManifest, report: inout UpgradeReport
  ) async -> Bool {
    guard let package = report.packagePath else {
      report.record(UpgradeReport.Name.installPackage, false, "no verified package")
      return false
    }
    do {
      try await deps.runner.runChecked([Self.installer, "-pkg", package, "-target", "/"])
      report.installed = true
      report.record(
        UpgradeReport.Name.installPackage, true, "\(manifest.package) \(manifest.version)")
      return true
    } catch {
      report.record(UpgradeReport.Name.installPackage, false, Self.describe(error))
      // The previous install is still on disk — `installer` either replaces a payload or does
      // nothing — so the recovery is simply to start what is already there again.
      deps.io.say("The package did not install; restarting the version that was already here.")
      _ = try? await deps.runner.run([Self.launchctl, "bootstrap", domainTarget, plistPath])
      _ = try? await deps.launchd.waitForSocket(at: socketPath, timeout: options.socketTimeout)
      return false
    }
  }

  private func startStep(report: inout UpgradeReport) async -> Bool {
    do {
      try await deps.runner.runChecked([Self.launchctl, "bootstrap", domainTarget, plistPath])
      report.record(UpgradeReport.Name.start, true, "\(domainTarget) \(plistPath)")
    } catch {
      report.record(UpgradeReport.Name.start, false, Self.describe(error))
      return false
    }
    do {
      let elapsed = try await deps.launchd.waitForSocket(
        at: socketPath, timeout: options.socketTimeout)
      report.record(
        UpgradeReport.Name.socket, true, "\(socketPath) after \(elapsed.components.seconds)s")
      return true
    } catch {
      report.record(UpgradeReport.Name.socket, false, Self.describe(error))
      deps.io.say("The upgraded daemon did not publish its socket. Its early output is in "
        + "\(options.stateDir)/logs/runnerd/stdio.log")
      return false
    }
  }

  /// The one fact that decides whether a rollback is even legal. Recorded, never acted on here:
  /// the verdict belongs to the command layer, which is the half that runs `doctor`.
  private func schemaStep(_ report: inout UpgradeReport) async {
    report.schemaAfter = await schemaVersion()
    let before = report.schemaBefore.map(String.init) ?? "unknown"
    let after = report.schemaAfter.map(String.init) ?? "unknown"
    report.record(
      UpgradeReport.Name.schema, true,
      report.schemaUnchanged
        ? "unchanged at v\(after)"
        : "v\(before) -> v\(after); migrations are one-way, so rollback is manual")
  }

  func schemaVersion() async -> Int? {
    guard let result = try? await deps.runner.run([
      Self.sqlite3, databasePath, "SELECT MAX(version) FROM schema_migrations",
    ]), result.isSuccess else { return nil }
    let text = result.trimmedStdout
    // A database with the table but no rows answers with an empty line, which is schema 0 — not
    // "could not ask", which is what `nil` means and what blocks an automatic rollback.
    return text.isEmpty ? 0 : Int(text)
  }

  // MARK: - Post-upgrade

  public func resume(into report: inout UpgradeReport) async {
    do {
      let daemon = try await deps.connect(socketPath)
      let response = try await daemon.systemResume()
      report.record(UpgradeReport.Name.resume, true, "host is \(response.mode)")
    } catch {
      report.record(UpgradeReport.Name.resume, false, Self.describe(error))
      deps.io.say("The host is still drained. Resume it with: sudo runnerctl system resume")
    }
  }

  // MARK: - Helpers

  func confirm(_ prompt: String, default value: Bool) -> Bool {
    guard !options.assumeYes else {
      deps.io.say("\(prompt) yes (--yes)")
      return true
    }
    return deps.io.confirm(prompt, default: value)
  }

  private func finish(_ report: UpgradeReport) -> UpgradeReport {
    deps.io.heading("Result")
    for line in report.ladder { deps.io.say(line) }
    return report
  }

  static func versionsJSON(from: String, to: String, schemaBefore: Int?) -> String {
    let schema = schemaBefore.map(String.init) ?? "null"
    return """
      {
        "from": "\(from)",
        "to": "\(to)",
        "schemaBefore": \(schema)
      }

      """
  }

  /// `20260828T175735Z` — sortable, filename-safe, and unambiguous about its timezone.
  static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  /// POSIX single-quoting, for the one command that has to be a shell string. The state directory
  /// contains a space in every production install, so this is not theoretical.
  static func quote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  static func describe(_ error: any Error) -> String {
    guard let runnerError = error as? any RunnerError else { return "\(error)" }
    return "\(runnerError.code): \(runnerError.message)"
  }
}
