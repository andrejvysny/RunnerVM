import Foundation
import RunnerCore

/// One profile the plan will create.
public struct PlannedProfile: Sendable, Hashable {
  public var name: String
  public var guestOS: GuestOS
  public var image: String
  public var resources: ResourceSpec
  public var maxInstances: Int
  /// True while the profile is emitted as a commented block rather than an active entry.
  public var deferred: Bool

  public init(
    name: String, guestOS: GuestOS, image: String, resources: ResourceSpec, maxInstances: Int,
    deferred: Bool = false
  ) {
    self.name = name
    self.guestOS = guestOS
    self.image = image
    self.resources = resources
    self.maxInstances = maxInstances
    self.deferred = deferred
  }

  /// Spec §36: the runner registers under the profile name, and `self-hosted` is the label every
  /// self-hosted runner carries. Same list `RunnerSessionManager` builds at registration time.
  public var labels: [String] { ["self-hosted", name] }
}

/// Answers + facts, resolved into everything the installer needs and nothing it has to decide.
/// Pure: building a plan touches no files, runs no commands and reaches no network.
public struct SetupPlan: Sendable, Hashable {
  public var mode: ServiceDeploymentMode
  public var stateDir: String
  public var runtimeDir: String
  public var account: ServiceAccountSpec
  /// Written before the daemon first starts. Carries no `profiles:` block: a profile whose image
  /// is not in the store yet would make `config apply` fail or stall on a pull at boot.
  public var configWithoutProfiles: String
  /// Applied once the images are in place.
  public var configFinal: String
  public var profiles: [PlannedProfile]
  public var managed: [ManagedImageSourceConfig]
  /// Every `runs-on` label the finished host answers to, deduplicated and ordered.
  public var labels: [String]
  public var linuxImage: String

  public var configPath: String { "\(stateDir)/config.yaml" }
  public var socketPath: String { "\(runtimeDir)/runnerd.sock" }
  /// The profiles that will be live after `config apply`, as opposed to the deferred macOS one.
  public var activeProfiles: [PlannedProfile] { profiles.filter { !$0.deferred } }
}

/// `SetupAnswers` + `SetupHostFacts` -> `SetupPlan`.
public enum SetupPlanner {
  public static func plan(
    answers: SetupAnswers,
    facts: SetupHostFacts,
    stateDir: String = SetupDefaults.stateDir,
    runtimeDir: String = SetupDefaults.runtimeDir,
    linuxImage: String = SetupDefaults.linuxImage
  ) -> SetupPlan {
    var profiles: [PlannedProfile] = []
    if answers.linuxEnabled {
      profiles.append(PlannedProfile(
        name: answers.linuxProfileName, guestOS: .linux, image: linuxImage,
        resources: SetupDefaults.linuxResources, maxInstances: answers.linuxConcurrency))
    }
    if answers.macOSEnabled {
      // Deferred on purpose: the managed image does not exist until a provisioning run has
      // produced and promoted it, and a macOS profile's `disk` must equal the image's exact
      // virtual size, which is not knowable before that run. See `SetupYAML.macOSProfileBlock`.
      profiles.append(PlannedProfile(
        name: answers.macOSProfileName, guestOS: .macos, image: answers.managedImageName,
        resources: ResourceSpec(
          cpuCount: SetupDefaults.macOSResources.cpuCount,
          memoryBytes: SetupDefaults.macOSResources.memoryBytes,
          diskBytes: 0),
        maxInstances: answers.macOSConcurrency,
        deferred: true))
    }

    let managed: [ManagedImageSourceConfig] = answers.macOSEnabled
      ? [ManagedImageSourceConfig(
        name: answers.managedImageName, kind: .macosTart, source: answers.macOSSource,
        autoUpdate: true, resources: SetupDefaults.macOSResources)]
      : []

    let context = SetupYAML.Context(
      answers: answers, facts: facts, stateDir: stateDir, profiles: profiles, managed: managed)

    return SetupPlan(
      mode: answers.mode,
      stateDir: stateDir,
      runtimeDir: runtimeDir,
      account: ServiceAccountSpec(home: "\(stateDir)/home"),
      configWithoutProfiles: SetupYAML.render(context, includeProfiles: false),
      configFinal: SetupYAML.render(context, includeProfiles: true),
      profiles: profiles,
      managed: managed,
      labels: labels(of: profiles),
      linuxImage: linuxImage)
  }

  /// `self-hosted` once, then each active profile's own label. A deferred profile contributes
  /// nothing: nothing answers to its label until it is activated.
  static func labels(of profiles: [PlannedProfile]) -> [String] {
    var seen: [String] = []
    for profile in profiles where !profile.deferred {
      for label in profile.labels where !seen.contains(label) { seen.append(label) }
    }
    return seen
  }
}
