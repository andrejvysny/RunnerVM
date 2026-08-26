import Foundation
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// `InstanceManager.create` and its lifecycle-ladder helpers. Split out of `InstanceManager.swift`
/// to keep that file under its line budget; every member below runs actor-isolated on
/// `InstanceManager` exactly as if it were declared there.
extension InstanceManager {
  // MARK: - Create

  /// Reserves capacity, materializes the clone, spawns a fenced worker and boots the VM.
  ///
  /// The instance id is generated up front and handed to `images.reserve`, which resolves and
  /// inspects the image and pins it under the `planning` owner *inside* `ImageManager`'s actor --
  /// the same serialization point `prune`/`delete` run on -- so a concurrent `image.prune` cannot
  /// delete the image between inspection and use. Any failure before the row lands releases that
  /// pin; success converts it into the permanent `instance` pin (`plan(instanceId:...)`).
  public func create(profileName: String) async throws -> InstanceRecord {
    guard let profileRow = try await profiles.get(name: profileName) else {
      throw SchedulerError.unknownProfile(name: profileName)
    }
    guard profileRow.enabled else { throw OrchestrationError.profileDisabled(name: profileName) }
    let profile = try profileRow.decodedConfig()

    let instanceId = InstanceID.generate()
    let (digest, image) = try await images.reserve(
      reference: profile.image, for: instanceId, profile: profile.name)
    let record: InstanceRecord
    do {
      record = try await plan(
        instanceId: instanceId, digest: digest, image: image, profile: profile,
        profileRow: profileRow)
    } catch {
      try? await images.release(planning: instanceId)
      throw error
    }
    return try await bringUp(record, profile: profile)
  }

  /// Validates the image against the profile, admits it against host capacity, inserts the row
  /// and converts the `planning` pin into the permanent `instance` pin. The caller releases the
  /// `planning` pin if anything here throws.
  private func plan(
    instanceId: InstanceID, digest: ImageDigest, image: ImageInfo, profile: RunnerProfileConfig,
    profileRow: RunnerProfileRecord
  ) async throws -> InstanceRecord {
    guard image.metadata.os == profile.guestOS else {
      throw ImageError.incompatibleGuestOS(expected: profile.guestOS, actual: image.metadata.os)
    }
    try await enforceRunnerVersion(digest: digest, image: image)
    let reservation = DiskAccounting.estimatedAdditionalAllocation(
      for: profile.resources.diskBytes, image: image)
    try await InstanceAdmission(
      paths: paths, instances: instances, profiles: profiles, probe: probe,
      configuration: configuration
    ).admit(profile: profile, profileId: profileRow.id, reservationBytes: reservation)

    let record = makeRecord(
      id: instanceId, profile: profile, profileId: profileRow.id, digest: digest,
      reservation: reservation)
    try await instances.insert(record)
    // Convert: add the permanent pin before dropping the temporary one, so the digest is never
    // observably unpinned.
    try await imageRows.pin(ownerType: .instance, ownerId: record.id.rawValue, digest: digest)
    try await imageRows.unpin(ownerType: .planning, ownerId: instanceId.rawValue, digest: digest)
    logger.info(
      "instance planned",
      metadata: .context(profile: profileRow.id, instance: record.id, imageDigest: digest))
    return record
  }

  /// Spec §53. An image whose baked-in runner is past GitHub's 30-day update window would be
  /// refused work by GitHub anyway, so `imageUpdates.denyTooOldRunner` turns that into a refusal
  /// here — before the clone, and before a worker is spawned for a VM that could never take a job.
  /// Left off (the default) it warns once per digest and admits the instance: a daemon with no
  /// GitHub credential grades every image `unknown` and must keep scheduling.
  private func enforceRunnerVersion(digest: ImageDigest, image: ImageInfo) async throws {
    guard let runnerVersions,
          await runnerVersions.health(for: image.metadata) == .tooOld
    else { return }
    let latest = await runnerVersions.latest()?.version ?? "-"
    let imageVersion = image.metadata.runnerVersion
    guard (configuration?.imageUpdates ?? ImageUpdatesConfig()).denyTooOldRunner else {
      guard warnedRunnerTooOld.insert(digest).inserted else { return }
      let missed = await runnerVersions.firstMissedRelease(forVersion: imageVersion)
      logger.warning(
        "image runner software is past GitHub's update window",
        metadata: .context(imageDigest: digest).merging([
          "runner_version": .string(imageVersion ?? "-"), "latest_version": .string(latest),
          "first_missed_version": .string(missed?.version ?? "-"),
        ]) { $1 })
      return
    }
    throw ImageError.runnerTooOld(
      digest: digest, imageVersion: imageVersion, latestVersion: latest)
  }

  private func makeRecord(
    id: InstanceID, profile: RunnerProfileConfig, profileId: RunnerProfileID, digest: ImageDigest,
    reservation: UInt64
  ) -> InstanceRecord {
    InstanceRecord(
      id: id, profileId: profileId, imageDigest: digest, hostId: hostId,
      name: "rvm-\(profile.shortName)-\(RunnerPaths.shortID(id))",
      lifecycle: profile.lifecycle, state: .planned, desiredState: .waitingForAgent,
      cpuCount: profile.resources.cpuCount, memoryBytes: profile.resources.memoryBytes,
      diskBytes: profile.resources.diskBytes, diskReservationBytes: reservation,
      macAddress: InstanceSpecFile.randomMACAddress(),
      instancePath: paths.instanceDir(id).path(percentEncoded: false), createdAt: .now)
  }

  private func bringUp(
    _ record: InstanceRecord, profile: RunnerProfileConfig
  ) async throws -> InstanceRecord {
    var current = try await transition(record, to: .preparing)
    current = try await transition(current, to: .cloning)
    let layout = try await stage(current, profile: profile)
    current = try await transition(current, to: .startingWorker)
    let spawnedAt = ContinuousClock.now
    let session = try await spawn(current, specPath: layout.spec)
    await metrics.observe(
      RunnerVMMetrics.workerStartSeconds,
      labels: [RunnerVMMetrics.profileLabel: profile.name], since: spawnedAt)
    current = try await transition(current, to: .startingVM) { record in
      record.workerPid = session.pid
      record.workerSocket = session.socketPath.path(percentEncoded: false)
      record.startedAt = .now
    }
    await boot(current)
    return try await require(current.id)
  }

  private func stage(
    _ record: InstanceRecord, profile: RunnerProfileConfig
  ) async throws -> VMInstanceLayout {
    let spec = InstanceSpecFile(
      id: record.id, imageDigest: record.imageDigest, os: profile.guestOS,
      cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, diskBytes: record.diskBytes,
      macAddress: record.macAddress ?? InstanceSpecFile.randomMACAddress())
    let startedAt = ContinuousClock.now
    do {
      let materialized = try await instanceStore.materialize(
        instanceId: record.id, image: record.imageDigest, diskBytes: record.diskBytes, spec: spec)
      await metrics.observe(
        RunnerVMMetrics.instanceCloneSeconds,
        labels: [RunnerVMMetrics.profileLabel: profile.name], since: startedAt)
      // A running total, not a rate: what matters operationally is whether this host ever fell
      // back to a full copy, not how often per second (spec §20).
      await metrics.increment(
        RunnerVMMetrics.instanceCloneMethod,
        labels: [RunnerVMMetrics.methodLabel: materialized.cloneMethod.rawValue])
      return materialized.layout
    } catch {
      await fail(record, phase: "cloning", error: error)
      throw error
    }
  }

  func spawn(_ record: InstanceRecord, specPath: URL) async throws -> WorkerSession {
    do {
      return try await supervisor.start(instance: record, specPath: specPath)
    } catch {
      await fail(record, phase: "startingWorker", error: error)
      throw error
    }
  }

  /// vmworker boots the guest as soon as it publishes its socket, so `vm.start` is a confirmation
  /// rather than a trigger; the `running` edge may equally arrive as an event first.
  func boot(_ record: InstanceRecord) async {
    do {
      await applyVMState(record.id, try await supervisor.startVM(id: record.id))
    } catch {
      await fail(record, phase: "startingVM", error: error)
    }
  }
}
