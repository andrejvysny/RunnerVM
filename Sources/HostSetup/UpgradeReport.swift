import DaemonAPI
import Foundation
import RunnerCore

/// Exactly the `DaemonClient` calls `Upgrader` needs, and nothing else — the same seam
/// `SmokeTestDaemon` and `SetupDaemon` are, for the same reason: `DaemonClient` is a concrete
/// actor, so a protocol is what lets a test drive an upgrade without a daemon.
///
/// Only the two host-mode calls are here. An upgrade never inspects images or instances: it drains,
/// swaps the binaries, and resumes.
public protocol UpgradeDaemon: Sendable {
  func systemDrain(wait: Bool, timeoutMs: Int64) async throws -> SystemModeResponse
  func systemResume() async throws -> SystemModeResponse
}

extension DaemonClient: UpgradeDaemon {}

/// One step of an upgrade, in the order `Upgrader` performed it. Same shape as `SetupStep` so the
/// two ladders print identically.
public struct UpgradeStep: Sendable, Hashable, Codable {
  public var name: String
  public var ok: Bool
  public var detail: String

  public init(name: String, ok: Bool, detail: String = "") {
    self.name = name
    self.ok = ok
    self.detail = detail
  }
}

/// What an upgrade did, plus everything the command layer needs to decide whether a rollback is
/// even legal (`docs/design/distribution.md`, "Upgrade policy": automatic rollback only when the
/// database schema has not advanced).
public struct UpgradeReport: Sendable, Hashable, Codable {
  public var steps: [UpgradeStep]
  /// `RunnerVMVersion.current` as the running `runnerctl` reports it.
  public var fromVersion: String
  /// The manifest's version, once one has been fetched.
  public var toVersion: String?
  /// `<state>/upgrades/backup-<timestamp>`, once the backup step has run.
  public var backupDirectory: String?
  /// The cached pkg for `fromVersion`, when `bootstrap.sh` (or a previous upgrade) left one.
  public var previousPackagePath: String?
  /// The pkg this upgrade downloaded and verified.
  public var packagePath: String?
  /// `MAX(version)` from `schema_migrations`, before and after. `nil` means the question could not
  /// be asked, which is treated as "cannot prove it is unchanged".
  public var schemaBefore: Int?
  public var schemaAfter: Int?
  /// True once `installer -pkg` has actually run: before that, the host is untouched.
  public var installed: Bool
  /// The owner (`user:group`) of the state directory's database, captured before the swap so a
  /// restore does not leave root-owned files a service-account daemon cannot write.
  public var stateOwner: String?

  public init(
    steps: [UpgradeStep] = [], fromVersion: String, toVersion: String? = nil,
    backupDirectory: String? = nil, previousPackagePath: String? = nil, packagePath: String? = nil,
    schemaBefore: Int? = nil, schemaAfter: Int? = nil, installed: Bool = false,
    stateOwner: String? = nil
  ) {
    self.steps = steps
    self.fromVersion = fromVersion
    self.toVersion = toVersion
    self.backupDirectory = backupDirectory
    self.previousPackagePath = previousPackagePath
    self.packagePath = packagePath
    self.schemaBefore = schemaBefore
    self.schemaAfter = schemaAfter
    self.installed = installed
    self.stateOwner = stateOwner
  }

  public var ok: Bool { steps.allSatisfy(\.ok) }
  public var failed: [UpgradeStep] { steps.filter { !$0.ok } }

  public func step(named name: String) -> UpgradeStep? { steps.first { $0.name == name } }

  /// Public because `runnerctl` appends the last three steps itself: `doctor`, `rollback` and
  /// `resume` are the command layer's decisions, and they belong in the same ladder.
  public mutating func record(_ name: String, _ ok: Bool, _ detail: String = "") {
    steps.append(UpgradeStep(name: name, ok: ok, detail: detail))
  }

  /// Provably unchanged, not merely "not known to have changed": an unanswerable query counts as
  /// advanced, because migrations are one-way and a wrong guess restores a database the new
  /// binaries have already migrated.
  public var schemaUnchanged: Bool {
    guard let schemaBefore, let schemaAfter else { return false }
    return schemaBefore == schemaAfter
  }

  /// The three conditions `docs/design/distribution.md` puts on an automatic rollback, minus the
  /// doctor verdict, which the command layer owns.
  public var rollbackAvailable: Bool {
    installed && schemaUnchanged && previousPackagePath != nil && backupDirectory != nil
  }

  /// The `✓`/`✗` ladder printed at the end of a run.
  public var ladder: [String] {
    steps.map { "\($0.ok ? "✓" : "✗") \($0.name)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
  }

  /// Step names, in one place so the upgrader and its tests cannot disagree on spelling.
  public enum Name {
    public static let manifest = "release manifest"
    public static let download = "download"
    public static let checksum = "checksum"
    public static let rollbackMaterial = "rollback pkg"
    public static let confirmation = "confirmation"
    public static let backup = "backup"
    public static let drain = "drain"
    public static let stop = "daemon stopped"
    public static let installPackage = "pkg installed"
    public static let start = "daemon started"
    public static let socket = "daemon socket"
    public static let schema = "schema"
    /// Recorded by the command layer, which owns `DoctorChecks`.
    public static let doctor = "doctor"
    public static let rollback = "rollback"
    public static let resume = "resume"
  }
}

/// What `runnerctl upgrade --check` answers with: the two versions and the verdict, and nothing
/// that would require touching the host.
public struct UpgradeCheck: Sendable, Hashable, Codable {
  public enum Verdict: String, Sendable, Codable {
    case upToDate
    case upgradeAvailable
    /// The installed build is newer than the release — a development or pre-release host.
    case newerInstalled
    /// One of the two strings did not parse as a version; the upgrade is still offered, because a
    /// mismatched string is not a reason to refuse.
    case unknown
  }

  public var current: String
  public var latest: String
  public var verdict: Verdict
  public var manifest: ReleaseManifest

  public init(current: String, latest: String, verdict: Verdict, manifest: ReleaseManifest) {
    self.current = current
    self.latest = latest
    self.verdict = verdict
    self.manifest = manifest
  }

  public init(current: String, manifest: ReleaseManifest) {
    let installed = SemanticVersion(tag: current)
    let released = SemanticVersion(tag: manifest.version)
    let verdict: Verdict = switch (installed, released) {
    case let (installed?, released?) where installed < released: .upgradeAvailable
    case let (installed?, released?) where released < installed: .newerInstalled
    case (_?, _?): .upToDate
    default: .unknown
    }
    self.init(
      current: current, latest: manifest.version, verdict: verdict, manifest: manifest)
  }

  /// True when running the upgrade would actually change anything.
  public var upgradeAvailable: Bool { verdict == .upgradeAvailable || verdict == .unknown }

  public var summary: String {
    switch verdict {
    case .upToDate: "up to date (\(current))"
    case .upgradeAvailable: "\(latest) is available (installed: \(current))"
    case .newerInstalled: "installed \(current) is newer than the released \(latest)"
    case .unknown: "installed \(current), released \(latest) (versions not comparable)"
    }
  }
}
