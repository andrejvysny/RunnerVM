import DaemonAPI
import Foundation
import GuestControl
import Persistence
import RunnerCore
import RunnerLogging
import Scheduler

/// `fleet.*` (`Proto/fleet.md`): leased VMs for the GitLab fleeting plugin. Every member runs
/// actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  // MARK: - Resolution

  private func gitlabProfile(
    _ name: String
  ) async throws -> (row: RunnerProfileRecord, config: RunnerProfileConfig) {
    guard let row = try await profiles.get(name: name) else {
      throw DaemonServiceError.notFound(entity: "profile", name: name)
    }
    guard row.provider == .gitlab else { throw FleetError.profileNotGitLab(name: name) }
    return (row, try row.decodedConfig())
  }

  /// The instance and its profile; `nil` when the id is unknown. A profile that still exists must
  /// be a gitlab one, and the instance itself must be a fleet instance.
  private func fleetInstance(_ id: String) async throws -> InstanceRecord? {
    guard let record = try await instanceRows.get(id: InstanceID(rawValue: id)) else { return nil }
    if let row = try await profiles.list().first(where: { $0.id == record.profileId }),
       row.provider != .gitlab {
      throw FleetError.profileNotGitLab(name: row.name)
    }
    guard record.purpose == .fleet else { throw FleetError.instanceNotFleet(id: id) }
    return record
  }

  private static func validateLease(_ leaseMs: Int64) throws {
    guard FleetLease.range.contains(leaseMs) else {
      throw FleetError.leaseInvalid(
        leaseMs: leaseMs, minimumMs: FleetLease.minimumMs, maximumMs: FleetLease.maximumMs)
    }
  }

  private static func leaseDeadline(_ leaseMs: Int64, now: Date) -> Date {
    now.addingTimeInterval(Double(leaseMs) / 1_000)
  }

  // MARK: - fleet.info / fleet.list

  /// `maxInstances` is what this profile could reach on an otherwise empty, admitting host: the
  /// plugin reads it once at Init as taskscaler's `MaxSize`, so a figure shrunk by whatever GitHub
  /// jobs or a drain happen to hold at that moment would cap the GitLab fleet until gitlab-runner
  /// restarts. `fleet.create` admission is what enforces the live budget.
  func fleetInfo(_ request: FleetInfoRequest) async throws -> FleetInfoResponse {
    let (row, config) = try await gitlabProfile(request.profile)
    let budget = InstanceAdmission.budget(
      configuration: appliedConfiguration(), probe: probe, paths: paths)
    let capacity = CapacityCalculator.profileCapacity(
      profileId: row.id, profile: config, reservations: [], budget: budget, hostMode: .normal)
    return FleetInfoResponse(
      profile: config.name, guestOS: config.guestOS.rawValue, arch: FleetSupport.arch,
      sshUser: InstanceSSHInfo.defaultUser, maxInstances: Int64(max(0, capacity.total)))
  }

  func fleetList(_ request: FleetListRequest) async throws -> FleetListResponse {
    let (row, _) = try await gitlabProfile(request.profile)
    let now = Date()
    let listed = try await instanceRows.list(profile: row.id, states: nil)
      .filter { $0.purpose == .fleet && FleetSupport.isListed($0, now: now) }
      .sorted { $0.createdAt.date < $1.createdAt.date }
    return FleetListResponse(
      instances: listed.map {
        FleetInstanceDTO(
          id: $0.id.rawValue, state: FleetSupport.state(for: $0.state),
          leaseUntil: $0.pinnedUntil.map { RFC3339.string(from: $0.date) })
      })
  }

  // MARK: - fleet.create / delete / renew

  func fleetCreate(_ request: FleetCreateRequest) async throws -> FleetCreateResponse {
    let (_, config) = try await gitlabProfile(request.profile)
    try Self.validateLease(request.leaseMs)
    let deadline = Self.leaseDeadline(request.leaseMs, now: Date())
    let record = try await createInstance(
      profileName: config.name,
      options: InstanceCreateOptions(purpose: .fleet, pinnedUntil: deadline))
    logger.notice(
      "fleet instance created",
      metadata: .context(profile: record.profileId, instance: record.id))
    return FleetCreateResponse(id: record.id.rawValue, leaseUntil: RFC3339.string(from: deadline))
  }

  func fleetDelete(_ request: FleetDeleteRequest) async throws -> FleetDeleteResponse {
    guard let record = try await fleetInstance(request.id) else {
      return FleetDeleteResponse(id: request.id, accepted: true)
    }
    if record.state != .deleted, record.state != .deleting {
      _ = try await instances.delete(id: record.id)
      logger.notice(
        "fleet instance deleted",
        metadata: .context(profile: record.profileId, instance: record.id))
    }
    return FleetDeleteResponse(id: request.id, accepted: true)
  }

  func fleetRenew(_ request: FleetRenewRequest) async throws -> FleetRenewResponse {
    try Self.validateLease(request.leaseMs)
    let deadline = Self.leaseDeadline(request.leaseMs, now: Date())
    var renewed: [String] = []
    for id in request.ids where !renewed.contains(id) {
      guard let record = try await instanceRows.get(id: InstanceID(rawValue: id)),
            record.purpose == .fleet, record.state != .deleted, record.state != .deleting,
            try await instanceRows.updatePinnedUntil(id: record.id, pinnedUntil: deadline) != nil
      else { continue }
      renewed.append(id)
    }
    return FleetRenewResponse(renewed: renewed)
  }

  // MARK: - fleet.connect

  func fleetConnect(_ request: FleetConnectRequest) async throws -> FleetConnectResponse {
    guard let record = try await fleetInstance(request.id) else {
      throw FleetError.instanceNotFound(id: request.id)
    }
    guard record.state == .idle else {
      throw FleetError.instanceNotReady(id: request.id, state: record.state.rawValue)
    }
    try FleetSupport.validatePublicKey(request.publicKey)
    guard let row = try await profiles.list().first(where: { $0.id == record.profileId }) else {
      throw DaemonServiceError.notFound(entity: "profile", name: record.profileId.rawValue)
    }
    let guestOS = row.guestOS
    let user = InstanceSSHInfo.defaultUser
    let info = try await instances.guestInfo(id: record.id)
    guard let address = FleetSupport.address(
      primary: info.primaryAddress, addresses: info.ipAddresses)
    else { throw FleetError.noAddress(id: request.id) }
    try await installKey(
      request.publicKey, user: user, guestOS: guestOS, id: record.id)
    logger.notice(
      "fleet ssh key installed",
      metadata: .context(profile: record.profileId, instance: record.id))
    return FleetConnectResponse(
      id: request.id, address: address, port: FleetSupport.sshPort, user: user,
      guestOS: guestOS.rawValue, arch: FleetSupport.arch)
  }

  /// The key travels only as an argv element; output is capped small and never surfaced, because
  /// nothing in it is needed and the error must not be a path for the key to leak through.
  private func installKey(
    _ key: String, user: String, guestOS: GuestOS, id: InstanceID
  ) async throws {
    let argv = FleetSupport.installArgv(
      user: user, home: FleetSupport.home(user: user, guestOS: guestOS), key: key)
    let events = try await instances.exec(
      id: id, ExecRequest(argv: argv, timeoutMs: 30_000, maxOutputBytes: 4_096))
    var exitCode: Int32?
    for try await event in events {
      if case .exited(let code) = event { exitCode = code }
    }
    guard exitCode == 0 else {
      throw FleetError.keyInstallFailed(id: id.rawValue, exitCode: exitCode ?? -1)
    }
  }
}
