import DaemonAPI
import Foundation

/// Exactly the `DaemonClient` calls `HostInstaller` needs once the socket is up, and nothing else
/// — the same seam `SmokeTestDaemon` is, for the same reason: `DaemonClient` is a concrete actor,
/// so a protocol is what lets a test drive the installer without a daemon or a VM.
///
/// Inherits `SmokeTestDaemon` because the installer's last step is a real smoke test over the
/// same connection.
public protocol SetupDaemon: SmokeTestDaemon {
  func authLogin(token: String) async throws -> AuthLoginResponse
  func githubTest() async throws -> GitHubTestResponse
  func imagePull(reference: String, format: String?) async throws -> ImagePullResponse
  func operationGet(id: String) async throws -> OperationInfo
  func configApply(yaml: String) async throws -> ConfigApplyResponse
  /// Drives the managed macOS source's build → qualify → promote run, and follows it. The run
  /// outlives the call, so `imageUpdateStatus` is the half that reports progress.
  func imageUpdateRun(managed: String?) async throws -> ImageUpdateStatusResponse
  func imageUpdateStatus() async throws -> ImageUpdateStatusResponse
  /// Reads the promoted image's exact virtual size, which is what a macOS profile's `disk` must
  /// equal — a macOS guest cannot resize its APFS container.
  func imageGet(ref: String) async throws -> ImageInfoDTO
}

extension DaemonClient: SetupDaemon {}

/// One step of an install, in the order `HostInstaller` performed it.
///
/// Mirrors `SmokeTestCheck`'s shape on purpose: same three fields, same "detail is always a
/// string" convention, so the two can be printed by one ladder.
public struct SetupStep: Sendable, Hashable, Codable {
  public var name: String
  public var ok: Bool
  public var detail: String

  public init(name: String, ok: Bool, detail: String = "") {
    self.name = name
    self.ok = ok
    self.detail = detail
  }
}

/// What an install did. `ok` is false when any step failed, including a step that was skipped
/// because an earlier one failed — an install that could not prove itself is not a success, even
/// though the daemon may well be running.
public struct SetupReport: Sendable, Hashable, Codable {
  public var steps: [SetupStep]
  /// True when the plan was printed rather than performed.
  public var dryRun: Bool
  /// The commands a dry run would have executed, in order.
  public var plannedCommands: [[String]]

  public init(steps: [SetupStep] = [], dryRun: Bool = false, plannedCommands: [[String]] = []) {
    self.steps = steps
    self.dryRun = dryRun
    self.plannedCommands = plannedCommands
  }

  public var ok: Bool { steps.allSatisfy(\.ok) }
  public var failed: [SetupStep] { steps.filter { !$0.ok } }

  public func step(named name: String) -> SetupStep? { steps.first { $0.name == name } }

  mutating func record(_ name: String, _ ok: Bool, _ detail: String = "") {
    steps.append(SetupStep(name: name, ok: ok, detail: detail))
  }

  /// The `✓`/`✗` ladder printed at the end of a run.
  public var ladder: [String] {
    steps.map { "\($0.ok ? "✓" : "✗") \($0.name)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
  }

  /// Step names, in one place so the installer and its tests cannot disagree on spelling.
  public enum Name {
    public static let account = "service account"
    public static let directories = "directories"
    public static let config = "config.yaml"
    public static let launchd = "launchd job"
    public static let socket = "daemon socket"
    public static let connect = "daemon connection"
    public static let auth = "github token"
    public static let githubTest = "github access"
    public static let imagePull = "linux image"
    public static let configApply = "profiles applied"
    public static let smokeTest = "smoke test"
    public static let macOSImage = "macos image"
    public static let macOSProfile = "macos profile"
    public static let macOSSmokeTest = "macos smoke test"
  }
}
