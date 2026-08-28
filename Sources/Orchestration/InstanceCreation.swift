import Foundation
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// Everything `instance.create` can ask for beyond "one VM of this profile".
///
/// Defaulted throughout, so the scheduler's own `create(profileName:)` and every pre-existing
/// call site keep meaning exactly what they meant before: an ordinary, unpinned runner VM.
public struct InstanceCreateOptions: Sendable, Hashable {
  /// `runner` (the scheduler owns it) or `maintenance` (pinned; the scheduler never plans it).
  public var purpose: InstancePurpose
  /// Absolute deadline `MaintenanceInstanceReaper` deletes the instance at. Required for
  /// `maintenance`, meaningless for `runner` — the daemon handler is what enforces that.
  public var pinnedUntil: Date?
  /// Replaces the profile's `image:` for this instance only. The override goes through the same
  /// `images.reserve` resolution/pin path the profile reference would, so a registry reference is
  /// pulled and a digest is pinned exactly as usual.
  public var imageOverride: String?

  public init(
    purpose: InstancePurpose = .runner, pinnedUntil: Date? = nil, imageOverride: String? = nil
  ) {
    self.purpose = purpose
    self.pinnedUntil = pinnedUntil
    self.imageOverride = imageOverride
  }

  /// What the scheduler asks for.
  public static let runner = InstanceCreateOptions()
}

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
  public func create(
    profileName: String, options: InstanceCreateOptions = .runner
  ) async throws -> InstanceRecord {
    guard let profileRow = try await profiles.get(name: profileName) else {
      throw SchedulerError.unknownProfile(name: profileName)
    }
    guard profileRow.enabled else { throw OrchestrationError.profileDisabled(name: profileName) }
    let profile = try profileRow.decodedConfig()

    let instanceId = InstanceID.generate()
    // The override stands in for the profile's reference here and nowhere else: every later check
    // (guest OS, macOS platform floors, runner freshness, admission) grades the image that was
    // actually reserved, which is the whole point of qualifying a candidate image this way.
    let (digest, image) = try await images.reserve(
      reference: options.imageOverride ?? profile.image, for: instanceId, profile: profile.name)
    let planned: (record: InstanceRecord, macos: MacOSInstancePlatformSpec?)
    do {
      planned = try await plan(
        instanceId: instanceId, digest: digest, image: image, profile: profile,
        profileRow: profileRow, options: options)
    } catch {
      try? await images.release(planning: instanceId)
      throw error
    }
    return try await bringUp(planned.record, profile: profile, macos: planned.macos)
  }

  /// Validates the image against the profile, admits it against host capacity, inserts the row
  /// and converts the `planning` pin into the permanent `instance` pin. The caller releases the
  /// `planning` pin if anything here throws.
  private func plan(
    instanceId: InstanceID, digest: ImageDigest, image: ImageInfo, profile: RunnerProfileConfig,
    profileRow: RunnerProfileRecord, options: InstanceCreateOptions
  ) async throws -> (record: InstanceRecord, macos: MacOSInstancePlatformSpec?) {
    guard image.metadata.os == profile.guestOS else {
      throw ImageError.incompatibleGuestOS(expected: profile.guestOS, actual: image.metadata.os)
    }
    let macos = try Self.macOSPlatformSpec(profile: profile, image: image)
    try await enforceRunnerVersion(digest: digest, image: image)
    let reservation = DiskAccounting.estimatedAdditionalAllocation(
      for: profile.resources.diskBytes, image: image)
    let record = makeRecord(
      id: instanceId, profile: profile, profileId: profileRow.id, digest: digest,
      reservation: reservation, options: options)
    try await admit(record, profile: profile, profileId: profileRow.id, reservation: reservation)
    // Convert: add the permanent pin before dropping the temporary one, so the digest is never
    // observably unpinned.
    try await imageRows.pin(ownerType: .instance, ownerId: record.id.rawValue, digest: digest)
    try await imageRows.unpin(ownerType: .planning, ownerId: instanceId.rawValue, digest: digest)
    logger.info(
      "instance planned",
      metadata: .context(profile: profileRow.id, instance: record.id, imageDigest: digest))
    return (record, macos)
  }

  /// What a macOS instance's `spec.json` must carry, and the refusals that go with it.
  ///
  /// Runs inside `plan`, before the row is inserted: an image that cannot describe its platform, or
  /// a profile sized below what the image will boot with, is a permanent misconfiguration, and
  /// leaving a `failed` row behind for it would only make the operator clean up after a create that
  /// never allocated anything. Linux never has a platform block (`ImageStore` refuses one).
  static func macOSPlatformSpec(
    profile: RunnerProfileConfig, image: ImageInfo
  ) throws -> MacOSInstancePlatformSpec? {
    guard profile.guestOS == .macos else { return nil }
    let platform = try macOSPlatform(image: image)
    let minimumCPU = platform.minimumCPUCount ?? 0
    let minimumMemory = platform.minimumMemoryBytes ?? 0
    if profile.resources.cpuCount < minimumCPU {
      throw VMError.macOSProfileCPUTooSmall(
        requested: profile.resources.cpuCount, minimum: minimumCPU)
    }
    if profile.resources.memoryBytes < minimumMemory {
      throw VMError.macOSProfileMemoryTooSmall(
        requestedBytes: profile.resources.memoryBytes, minimumBytes: minimumMemory)
    }
    try checkMacOSDiskContract(profile: profile, image: image)
    return platform
  }

  /// The `spec.json` platform block a macOS image describes, and the refusals that go with it.
  ///
  /// Split out of `macOSPlatformSpec` so the managed macOS provisioning builder (D7) applies the
  /// exact same image-side contract to the builder VM it boots -- the platform facts are the
  /// image's, and only the sizing comparison below them belongs to a profile.
  ///
  /// The minimums are mandatory, unlike the `nil`-tolerant model the fields were introduced with:
  /// an image that states no floor pushes the first real compatibility failure out of admission
  /// and into `VZVirtualMachineConfiguration.validate()`, inside a worker, after a clone and a boot.
  static func macOSPlatform(image: ImageInfo) throws -> MacOSInstancePlatformSpec {
    guard let platform = image.metadata.macos, !platform.hardwareModel.isEmpty else {
      throw VMError.macOSHardwareModelMissing
    }
    guard platform.minimumCPUCount != nil else {
      throw VMError.macOSImageMinimumsMissing(field: "minimumCPUCount")
    }
    guard platform.minimumMemoryBytes != nil else {
      throw VMError.macOSImageMinimumsMissing(field: "minimumMemoryBytes")
    }
    return MacOSInstancePlatformSpec(platform)
  }

  /// `resources.disk` has to name the macOS image's own size, exactly.
  ///
  /// The host enlarges `disk.img` before boot (`VMDirectoryStaging`) and the *guest* is what turns
  /// that space into filesystem. On darwin the guest agent cannot: `agent.resizeDisk` answers
  /// `NOT_SUPPORTED`, because growing an APFS container needs a recovery story RunnerVM does not
  /// have yet. A profile asking for more would therefore hand the job a bigger raw disk and
  /// exactly the image's original root volume -- capacity the job never receives.
  ///
  /// Asking for *less* is refused too, by `InstanceStore.materialize`
  /// (`IMAGE_DISK_SMALLER_THAN_IMAGE`), but only after the row and the reservation exist. Both
  /// directions are checked here instead, in `plan`, so a misconfigured profile never leaves a
  /// `failed` row behind for the operator to clean up.
  private static func checkMacOSDiskContract(
    profile: RunnerProfileConfig, image: ImageInfo
  ) throws {
    // The disk *layer*, not `image.virtualBytes` (which sums every layer, auxiliary storage
    // included) and not the metadata figure (which a hand-edited `metadata.json` can misstate):
    // this is the same number `InstanceStore.materialize` measures the request against.
    let imageBytes = image.manifest.layer(.disk)?.sizeBytes ?? image.metadata.virtualDiskSizeBytes
    guard profile.resources.diskBytes != imageBytes else { return }
    throw VMError.macOSDiskResizeUnsupported(
      requestedBytes: profile.resources.diskBytes, imageBytes: imageBytes)
  }

  /// The capacity critical section: reading the reservations, deciding they leave room and
  /// inserting the row that *is* the new reservation happen with nothing else admitted in between.
  /// Two concurrent creates would otherwise both measure the host before either had written its
  /// row and both proceed (spec §121).
  ///
  /// The body captures repositories and value types rather than `self`, so it stays `@Sendable`
  /// and the actor is free while the queue is contended.
  private func admit(
    _ record: InstanceRecord, profile: RunnerProfileConfig, profileId: RunnerProfileID,
    reservation: UInt64
  ) async throws {
    let paths = paths
    let instances = instances
    let profiles = profiles
    let probe = probe
    let configuration = configuration
    let builds = imageBuilds
    try await admissionQueue.admit {
      try await InstanceAdmission(
        paths: paths, instances: instances, profiles: profiles, probe: probe,
        configuration: configuration, builds: builds
      ).admit(profile: profile, profileId: profileId, reservationBytes: reservation)
      try await instances.insert(record)
    }
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
    reservation: UInt64, options: InstanceCreateOptions
  ) -> InstanceRecord {
    InstanceRecord(
      id: id, profileId: profileId, imageDigest: digest, hostId: hostId,
      name: "rvm-\(profile.shortName)-\(RunnerPaths.shortID(id))",
      lifecycle: profile.lifecycle, state: .planned, desiredState: .waitingForAgent,
      cpuCount: profile.resources.cpuCount, memoryBytes: profile.resources.memoryBytes,
      diskBytes: profile.resources.diskBytes, diskReservationBytes: reservation,
      macAddress: InstanceSpecFile.randomMACAddress(),
      instancePath: paths.instanceDir(id).path(percentEncoded: false), createdAt: .now,
      purpose: options.purpose, pinnedUntil: options.pinnedUntil.map(DatabaseDate.init))
  }

  private func bringUp(
    _ record: InstanceRecord, profile: RunnerProfileConfig, macos: MacOSInstancePlatformSpec?
  ) async throws -> InstanceRecord {
    var current = try await transition(record, to: .preparing)
    current = try await transition(current, to: .cloning)
    let layout = try await stage(current, profile: profile, macos: macos)
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
    _ record: InstanceRecord, profile: RunnerProfileConfig, macos: MacOSInstancePlatformSpec?
  ) async throws -> VMInstanceLayout {
    let spec = InstanceSpecFile(
      id: record.id, imageDigest: record.imageDigest, os: profile.guestOS,
      cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, diskBytes: record.diskBytes,
      macAddress: record.macAddress ?? InstanceSpecFile.randomMACAddress(), macos: macos)
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
