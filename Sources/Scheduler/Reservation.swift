import Foundation
import RunnerCore

/// One capacity-consuming instance. Taken at `planned` and released only after physical deletion
/// (spec §121), so the caller builds these from every row whose `state.consumesCapacity` is true.
public struct Reservation: Sendable, Hashable, Identifiable {
  public var instanceId: InstanceID
  public var profileId: RunnerProfileID
  public var guestOS: GuestOS
  public var cpuCount: Int
  public var memoryBytes: UInt64
  /// Worst-case commit including temporary clone/pull space, not the sparse allocation (spec §17).
  public var diskReservationBytes: UInt64
  public var state: InstanceState
  /// A JIT config was issued or the instance is running a job: cancelling it would strand a runner
  /// registration on GitHub, so the scheduler never picks it (plan C1 "Cancellation").
  public var bound: Bool
  public var createdAt: Date

  public var id: InstanceID {
    instanceId
  }

  public init(
    instanceId: InstanceID,
    profileId: RunnerProfileID,
    guestOS: GuestOS,
    cpuCount: Int,
    memoryBytes: UInt64,
    diskReservationBytes: UInt64,
    state: InstanceState,
    bound: Bool,
    createdAt: Date
  ) {
    self.instanceId = instanceId
    self.profileId = profileId
    self.guestOS = guestOS
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskReservationBytes = diskReservationBytes
    self.state = state
    self.bound = bound
    self.createdAt = createdAt
  }

  /// States before the guest agent is reachable: nothing is registered with GitHub yet, so an
  /// unbound instance here can be torn down without reconciliation (spec §107).
  public static let preBootStates: Set<InstanceState> = [
    .planned, .preparing, .cloning, .startingWorker, .startingVM, .waitingForAgent,
  ]

  public var isCancellablePreBoot: Bool {
    !bound && Self.preBootStates.contains(state)
  }

  public var isCancellableIdle: Bool {
    !bound && state == .idle
  }
}

public extension RunnerProfileID {
  /// Sentinel profile an in-flight image build reserves capacity under. `@` cannot appear in a
  /// configured profile name, so every per-profile filter (`profileCapacity`'s instance count,
  /// `InstanceAdmission`'s `maxInstances` check, `DesiredCapacity`'s reservation slice) skips it
  /// while the host-wide totals in `CapacityCalculator.fits` still charge for it.
  static let imageBuild = RunnerProfileID(rawValue: "@image-build")
}

public extension Reservation {
  /// The cpu/memory/disk a running image build holds against the host budget. A build owns a VM
  /// that is producing an artifact, so it is `bound` and in a running state: neither
  /// `isCancellablePreBoot` nor `isCancellableIdle` can ever select it, and the scheduler has no
  /// way to reclaim it (spec §121).
  ///
  /// `guestOS` defaults to `.linux`; a builder producing a macOS image passes `.macos` so the
  /// build also counts against `HostConstants.macOSGuestLimit`.
  static func imageBuild(
    id: String,
    cpuCount: Int,
    memoryBytes: UInt64,
    diskBytes: UInt64,
    createdAt: Date,
    guestOS: GuestOS = .linux
  ) -> Reservation {
    Reservation(
      instanceId: InstanceID(rawValue: id),
      profileId: .imageBuild,
      guestOS: guestOS,
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      diskReservationBytes: diskBytes,
      state: .busy,
      bound: true,
      createdAt: createdAt
    )
  }

  /// True for a reservation that belongs to an image build rather than to a runner instance.
  var isImageBuild: Bool {
    profileId == .imageBuild
  }
}

/// The resource ask of one prospective instance.
public struct ResourceRequest: Sendable, Hashable {
  public var guestOS: GuestOS
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskReservationBytes: UInt64

  public init(guestOS: GuestOS, cpuCount: Int, memoryBytes: UInt64, diskReservationBytes: UInt64) {
    self.guestOS = guestOS
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskReservationBytes = diskReservationBytes
  }

  /// `diskReservationBytes` defaults to the profile's virtual disk size; callers that also stage a
  /// clone or a pull pass a larger explicit value.
  public init(profile: RunnerProfileConfig, diskReservationBytes: UInt64? = nil) {
    self.init(
      guestOS: profile.guestOS,
      cpuCount: profile.resources.cpuCount,
      memoryBytes: profile.resources.memoryBytes,
      diskReservationBytes: diskReservationBytes ?? profile.resources.diskBytes
    )
  }
}

extension Reservation {
  /// Turns a request into the reservation it would become. Used to simulate placement inside a
  /// single scheduling pass; the ids are synthetic and never persisted.
  static func simulated(
    request: ResourceRequest,
    profileId: RunnerProfileID,
    sequence: Int
  ) -> Reservation {
    Reservation(
      instanceId: InstanceID(rawValue: "simulated-\(profileId.rawValue)-\(sequence)"),
      profileId: profileId,
      guestOS: request.guestOS,
      cpuCount: request.cpuCount,
      memoryBytes: request.memoryBytes,
      diskReservationBytes: request.diskReservationBytes,
      state: .planned,
      bound: false,
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }
}
