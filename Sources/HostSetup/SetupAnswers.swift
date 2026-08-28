import Foundation
import RunnerCore

/// Which GitHub scope the runners register against.
public enum SetupScope: Sendable, Hashable {
  case repository(owner: String, repository: String)
  case organization(owner: String)

  /// The `github.scopes[].name` the generated document uses, and what every profile's `scope:`
  /// points at.
  public var configName: String {
    switch self {
    case .repository: "repo"
    case .organization: "org"
    }
  }

  public var kind: GitHubScopeKind {
    switch self {
    case .repository: .repository
    case .organization: .organization
    }
  }

  public var owner: String {
    switch self {
    case let .repository(owner, _): owner
    case let .organization(owner): owner
    }
  }

  public var repository: String? {
    switch self {
    case let .repository(_, repository): repository
    case .organization: nil
    }
  }

  public var description: String {
    switch self {
    case let .repository(owner, repository): "repository \(owner)/\(repository)"
    case let .organization(owner): "organization \(owner)"
    }
  }

  /// Parses `--scope repo:<owner>/<repo>` / `--scope org:<owner>`. Returns `nil` for anything
  /// else so the caller can report a usage error with the exact accepted forms.
  public static func parse(_ text: String) -> SetupScope? {
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[1].isEmpty else { return nil }
    let value = String(parts[1])
    switch parts[0] {
    case "org", "organization":
      return value.contains("/") ? nil : .organization(owner: value)
    case "repo", "repository":
      let slug = value.split(separator: "/", omittingEmptySubsequences: false)
      guard slug.count == 2, !slug[0].isEmpty, !slug[1].isEmpty else { return nil }
      return .repository(owner: String(slug[0]), repository: String(slug[1]))
    default:
      return nil
    }
  }
}

/// Everything the wizard (or the non-interactive flag set) decided. Pure data: turning this into a
/// `SetupPlan` is `SetupPlanner`'s job, and nothing here touches the host.
public struct SetupAnswers: Sendable, Hashable {
  public var mode: ServiceDeploymentMode
  public var scope: SetupScope
  /// Organization scopes only; GitHub's own default group is literally named `Default`.
  public var runnerGroup: String
  /// Empty means the operator skipped it: the daemon installs and runs, but is not schedulable
  /// until `runnerctl auth login` supplies one.
  public var token: String
  public var linuxEnabled: Bool
  public var macOSEnabled: Bool
  public var macOSSource: String
  public var linuxConcurrency: Int
  public var macOSConcurrency: Int
  public var linuxProfileName: String
  public var macOSProfileName: String
  /// The `images.managed[]` alias the macOS profile's `image:` names. Deliberately outside the
  /// `rvm-<host6>-` namespace so it can never collide with a profile name.
  public var managedImageName: String

  public init(
    mode: ServiceDeploymentMode = .daemon,
    scope: SetupScope,
    runnerGroup: String = SetupDefaults.runnerGroup,
    token: String = "",
    linuxEnabled: Bool = true,
    macOSEnabled: Bool = false,
    macOSSource: String = SetupDefaults.macOSSource,
    linuxConcurrency: Int = 1,
    macOSConcurrency: Int = 1,
    linuxProfileName: String,
    macOSProfileName: String,
    managedImageName: String = SetupDefaults.managedImageName
  ) {
    self.mode = mode
    self.scope = scope
    self.runnerGroup = runnerGroup
    self.token = token
    self.linuxEnabled = linuxEnabled
    self.macOSEnabled = macOSEnabled
    self.macOSSource = macOSSource
    self.linuxConcurrency = linuxConcurrency
    self.macOSConcurrency = macOSConcurrency
    self.linuxProfileName = linuxProfileName
    self.macOSProfileName = macOSProfileName
    self.managedImageName = managedImageName
  }
}

/// The fixed defaults `setup` starts from, in one place so the wizard, the flags and the docs
/// cannot disagree.
public enum SetupDefaults {
  public static let stateDir = "/Library/Application Support/RunnerVM"
  public static let runtimeDir = "/var/run/runnervm"
  public static let runnerGroup = "Default"
  /// The public RunnerVM Linux image: a directly-runnable GHCR image with the guest agent baked in.
  public static let linuxImage = "ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable"
  /// A Tart export: never runnable as pulled, always provisioned locally first.
  public static let macOSSource = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
  public static let managedImageName = "macos-tahoe-base"
  public static let profilePrefix = "rvm"

  /// `rvm-<host6>` — the per-host prefix that keeps two hosts in one GitHub scope from fighting
  /// over the same scale-set session (`docs/design/distribution.md`, "Default profile naming").
  public static func profilePrefix(hostID6: String) -> String {
    hostID6.isEmpty ? profilePrefix : "\(profilePrefix)-\(hostID6)"
  }

  public static func linuxProfileName(prefix: String) -> String { "\(prefix)-ubuntu-24" }
  public static func macOSProfileName(prefix: String) -> String { "\(prefix)-macos-tahoe" }

  /// Sizing for the generated Linux profile. Deliberately smaller than
  /// `ResourceSpec.defaults(for: .linux)`: a fresh install should fit more than one runner on a
  /// base Mac mini, and the shipped ubuntu-24 image carries a 16 GiB disk layer, so a larger
  /// `disk` would reserve space no instance can use.
  public static let linuxResources = ResourceSpec(
    cpuCount: 2, memoryBytes: ByteSize.gibibytes(4).bytes, diskBytes: ByteSize.gibibytes(16).bytes)

  /// Host headroom the generated document reserves. `disk` is lower than
  /// `HostConfig.Reserve()`'s 50 GiB: that default was written for a host storing several images,
  /// and 20 GiB is what a single-profile install actually needs to keep macOS healthy.
  public static let reserve = HostConfig.Reserve(
    cpu: 2, memoryBytes: ByteSize.gibibytes(6).bytes, diskBytes: ByteSize.gibibytes(20).bytes)

  /// Sizing for the macOS provisioning VM (`images.managed[].resources`).
  public static let macOSResources = ManagedImageSourceConfig.Resources(
    cpuCount: 4, memoryBytes: ByteSize.gibibytes(8).bytes)

  /// Apple's standard licence allowance, and RunnerVM's fixed per-host cap.
  public static let macOSMaxConcurrency = HostConstants.macOSGuestLimit
}
