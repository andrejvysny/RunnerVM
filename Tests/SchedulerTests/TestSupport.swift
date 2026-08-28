import Foundation
import RunnerCore
@testable import Scheduler

/// Seeded PRNG so every property test is reproducible; Swift's `SystemRandomNumberGenerator`
/// would make failures unrepeatable.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    Int.random(in: range, using: &self)
  }

  mutating func bool() -> Bool {
    Bool.random(using: &self)
  }

  mutating func pick<T>(_ values: [T]) -> T {
    values[int(0 ... (values.count - 1))]
  }
}

enum Fixture {
  static let gib = UInt64(1) << 30
  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  static func resources(
    cpus: Int = 10,
    memoryGiB: UInt64 = 32,
    freeDiskGiB: UInt64 = 1000
  ) -> HostResources {
    HostResources(
      logicalCPUs: cpus,
      physicalMemoryBytes: memoryGiB * gib,
      freeDiskBytes: freeDiskGiB * gib
    )
  }

  static func hostConfig(
    cpuReserve: Int = 2,
    memoryReserveGiB: UInt64 = 6,
    diskReserveGiB: UInt64 = 50,
    cpuOvercommit: Double = 1.0,
    memoryOvercommit: Double = 1.0,
    diskOvercommit: Double = 1.0,
    maxVMs: HostConfig.MaxVMs = .auto
  ) -> HostConfig {
    HostConfig(
      reserve: HostConfig.Reserve(
        cpu: cpuReserve,
        memoryBytes: memoryReserveGiB * gib,
        diskBytes: diskReserveGiB * gib
      ),
      overcommit: HostConfig.Overcommit(
        cpu: cpuOvercommit, memory: memoryOvercommit, disk: diskOvercommit),
      maxVMs: maxVMs
    )
  }

  static func budget(
    config: HostConfig = hostConfig(),
    resources: HostResources = resources()
  ) -> HostBudget {
    HostBudget(config: config, resources: resources)
  }

  static func profile(
    name: String = "linux-small",
    guestOS: GuestOS = .linux,
    cpu: Int = 4,
    memoryGiB: UInt64 = 8,
    diskGiB: UInt64 = 80,
    minIdle: Int = 0,
    maxIdle: Int = 0,
    maxInstances: Int? = nil
  ) -> RunnerProfileConfig {
    RunnerProfileConfig(
      name: name,
      scope: "acme",
      image: "ghcr.io/acme/\(name):v1",
      guestOS: guestOS,
      resources: ResourceSpec(
        cpuCount: cpu, memoryBytes: memoryGiB * gib, diskBytes: diskGiB * gib
      ),
      warmPool: WarmPoolPolicy(minIdle: minIdle, maxIdle: maxIdle),
      limits: ProfileLimits(maxInstances: maxInstances)
    )
  }

  static func reservation(
    id: String,
    profile: String = "linux-small",
    guestOS: GuestOS = .linux,
    cpu: Int = 4,
    memoryGiB: UInt64 = 8,
    diskGiB: UInt64 = 80,
    state: InstanceState = .idle,
    bound: Bool = false,
    ageSeconds: TimeInterval = 0
  ) -> Reservation {
    Reservation(
      instanceId: InstanceID(rawValue: id),
      profileId: RunnerProfileID(rawValue: profile),
      guestOS: guestOS,
      cpuCount: cpu,
      memoryBytes: memoryGiB * gib,
      diskReservationBytes: diskGiB * gib,
      state: state,
      bound: bound,
      createdAt: epoch.addingTimeInterval(ageSeconds)
    )
  }

  static func request(_ profile: RunnerProfileConfig) -> ResourceRequest {
    ResourceRequest(profile: profile)
  }

  /// Reservations that match a profile, so capacity and desired-state math see one consistent set.
  static func reservations(
    of profile: RunnerProfileConfig,
    profileId: String,
    states: [InstanceState],
    bound: Bool = false
  ) -> [Reservation] {
    states.enumerated().map { index, state in
      reservation(
        id: "\(profileId)-\(index)",
        profile: profileId,
        guestOS: profile.guestOS,
        cpu: profile.resources.cpuCount,
        memoryGiB: profile.resources.memoryBytes / gib,
        diskGiB: profile.resources.diskBytes / gib,
        state: state,
        bound: bound,
        ageSeconds: TimeInterval(index) * 60
      )
    }
  }
}
