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
    let planned: (record: InstanceRecord, macos: MacOSInstancePlatformSpec?)
    do {
      // The override stands in for the profile's reference here and nowhere else: every later check
      // (guest OS, macOS platform floors, runner freshness, admission) grades the image that was
      // actually reserved, which is the whole point of qualifying a candidate image this way.
      //
      // Inside the `do` because `reserve` can throw *after* it has pinned: `timeouts.imagePull`
      // races a deadline against the resolution, and losing that race must not leave the planning
      // pin the winning branch may have just committed.
      let (digest, image) = try await images.reserve(
        reference: options.imageOverride ?? profile.image, for: instanceId, profile: profile.name,
        pullTimeout: profile.effectiveTimeouts.imagePull)
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
    // `timeouts.vmBoot` covers the whole clone -> running window, starting here. A host that is
    // slow at the clone or at the spawn produces exactly the symptom the timeout exists for -- a
    // VM that never comes up -- so all three phases are charged against one budget, and each
    // reports the phase it was actually in.
    let deadline = ContinuousClock.now + profile.effectiveTimeouts.vmBoot.duration
    let layout = try await stage(current, profile: profile, macos: macos)
    // Checked after the clone rather than around it: `clonefile(2)` is synchronous and has no
    // cancellation point, so an overrun can only ever be noticed once the copy is done.
    try await enforceBootDeadline(current.id, deadline: deadline, stage: "the instance disk clone")
    current = try await transition(current, to: .startingWorker)
    let spawnedAt = ContinuousClock.now
    let session = try await spawn(current, specPath: layout.spec)
    await metrics.observe(
      RunnerVMMetrics.workerStartSeconds,
      labels: [RunnerVMMetrics.profileLabel: profile.name], since: spawnedAt)
    // `workerPid` is stamped by the transition below, so the row does not carry it yet: the
    // failure record would otherwise name no worker for a phase that definitely spawned one.
    try await enforceBootDeadline(
      current.id, deadline: deadline, stage: "the worker to start", workerPID: session.pid)
    current = try await transition(current, to: .startingVM) { record in
      record.workerPid = session.pid
      record.workerSocket = session.socketPath.path(percentEncoded: false)
      record.startedAt = .now
    }
    await boot(current)
    // What is left of the budget belongs to the guest, and `instance.create` does not wait for it:
    // a boot is minutes of work and the caller's socket would idle out long before it landed. The
    // row goes back as `startingVM` and this watches the rest of the window instead.
    watchBoot(current, deadline: deadline)
    return try await require(current.id)
  }

  // MARK: - Boot deadline (`timeouts.vmBoot`)

  /// Ends a create whose boot budget is already spent, attributing the overrun to the phase the row
  /// is in right now, and throws so the caller (and the scheduler's hold-down) learns about it.
  private func enforceBootDeadline(
    _ id: InstanceID, deadline: ContinuousClock.Instant, stage: String, workerPID: Int32? = nil
  ) async throws {
    guard ContinuousClock.now >= deadline else { return }
    let fresh = try await require(id)
    await failBootTimeout(
      id, expecting: fresh.state, generation: fresh.workerGeneration, stage: stage,
      workerPID: workerPID)
    throw VMError.bootTimeout(stage: stage)
  }

  /// Bounds `startingVM -> waitingForAgent` from a task the actor owns, so the create RPC does not
  /// have to stay open for the guest's boot. Replaces any watcher already on this instance: only
  /// the newest boot of a row is the one worth bounding.
  func watchBoot(_ record: InstanceRecord, deadline: ContinuousClock.Instant) {
    bootWatchers[record.id]?.cancel()
    bootWatchers[record.id] = Task { [weak self] in
      await self?.awaitVMRunning(record, deadline: deadline)
    }
  }

  /// Re-arms the boot deadline after a daemon restart (`recheckAgents`, first reconcile tick).
  ///
  /// A watcher only ever lived in memory, so a restart used to lose it: a row whose worker survived
  /// stayed in `startingVM` with nothing bounding it, holding cpu, memory, disk and an image pin
  /// until an operator noticed. The budget is *rebuilt* from `started_at` -- stamped when the row
  /// entered `startingVM` -- rather than restarted, so a daemon that crashes often cannot extend one
  /// boot indefinitely; a row already past it is failed by the watcher's first poll, through the
  /// same compare-and-swap every other timeout goes through.
  func rearmBootWatch(_ record: InstanceRecord) async {
    let id = record.id
    // A worker that is gone belongs to `InstanceReconciler.interruptDeadWorkers`, which runs on
    // this same tick and interrupts the row; arming a deadline against it would race that.
    // `worker_generation == 0` is unreachable through the ladder -- `startingVM` is only entered
    // after `supervisor.start` has bumped it -- and both recovery paths skip such a row anyway
    // (`reconnectAll` and `interruptDeadWorkers` have the same guard), so it is left alone here too.
    guard record.state == .startingVM, record.workerGeneration > 0,
          await supervisor.liveness(id: id) != .dead else { return }
    // The worker's own view of the guest comes first. A VM that reached `running` while runnerd was
    // away has no event left to send -- the state it would report already changed -- and failing
    // that boot on a deadline would take down a VM that is up.
    if let reported = await supervisor.state(id: id) {
      await applyVMState(id, reported, adopted: true)
    }
    guard let fresh = try? await require(id), fresh.state == .startingVM else { return }
    let budget = await vmBootTimeout(for: fresh)
    let started = (fresh.startedAt ?? fresh.createdAt).date
    let elapsed = Duration.seconds(tuning.now().timeIntervalSince(started))
    // Clamped at both ends: a clock that moved backwards must not hand out more than the profile's
    // window, and one that moved forwards must not produce a deadline in the future.
    let remaining = min(budget, max(.zero, budget - elapsed))
    logger.info(
      "boot deadline re-armed",
      metadata: .context(profile: fresh.profileId, instance: id, host: hostId).merging([
        "remaining_ms": .stringConvertible(DurationValue(remaining).milliseconds),
      ]) { $1 })
    watchBoot(fresh, deadline: ContinuousClock.now + remaining)
  }

  /// Polls the row out of `startingVM`: a boot that lands, a teardown, an interruption and a
  /// restart all end the watch silently, and only the deadline itself synthesizes a failure.
  private func awaitVMRunning(
    _ record: InstanceRecord, deadline: ContinuousClock.Instant
  ) async {
    let id = record.id
    var reportedRefusal = false
    while !Task.isCancelled {
      // The generation is what makes this watcher belong to *this* boot: a reusable row that was
      // interrupted and respawned is back in `startingVM` on a budget of its own, and this one
      // must not fail it.
      guard let fresh = try? await require(id), fresh.state == .startingVM,
            fresh.workerGeneration == record.workerGeneration else { break }
      if ContinuousClock.now >= deadline {
        if await failBootTimeout(
          id, expecting: .startingVM, generation: record.workerGeneration,
          stage: "the VM to report running") { break }
        // The commit was refused. Either the race this is built to lose -- the row moved, or a
        // restart claimed a new generation -- which the next poll sees and retires on, or a
        // database fault, and a row that is still booting must stay bounded rather than have its
        // deadline dropped on the floor. So the watch continues, and says so once.
        if !reportedRefusal {
          reportedRefusal = true
          logger.warning(
            "boot deadline expired but the instance could not be failed; still watching",
            metadata: .context(instance: id))
        }
      }
      do { try await Task.sleep(for: tuning.vmRunningPollInterval) } catch { break }
    }
    // Only a watch that ran to its own end clears the slot: a cancelled one may already have been
    // replaced by a restart's, and removing the successor would leave that boot unbounded.
    if !Task.isCancelled { bootWatchers.removeValue(forKey: id) }
  }

  /// Fails an instance whose `timeouts.vmBoot` window closed, and takes its worker down with it.
  ///
  /// Nothing is written before the compare-and-swap in `fail` lands: a `running` event that beat
  /// the deadline by microseconds wins the row, and this must then leave no `failure.json`, no
  /// failure metric and no shutdown of a worker whose guest is up. The worker only goes once the
  /// row is `failed`, inside the same `teardown` bracket every stop takes -- it holds the instance
  /// lock, the vsock bridge and the guest, and its disconnect is expected rather than a second
  /// interruption. The directory stays: it is the only evidence of why the VM never booted.
  @discardableResult
  func failBootTimeout(
    _ id: InstanceID, expecting state: InstanceState, generation: Int, stage: String,
    workerPID: Int32? = nil
  ) async -> Bool {
    guard let fresh = try? await require(id), fresh.state == state,
          fresh.workerGeneration == generation else { return false }
    await afterBootTimeoutRead?()
    // The reading above is handed to the compare-and-swap rather than re-read inside `fail`: every
    // `await` between the two is a window a `running` event can land in, and `waitingForAgent ->
    // failed` is a legal edge, so a re-read would happily fail a guest that had just come up.
    guard await fail(
      fresh, phase: state.rawValue, error: VMError.bootTimeout(stage: stage),
      expecting: state, generation: generation, workerPID: workerPID)
    else { return false }
    teardown.insert(id)
    defer { teardown.remove(id) }
    let graceMs = await gracefulShutdownMs(for: fresh)
    if await supervisor.liveness(id: id) == .connected {
      try? await supervisor.shutdown(id: id, reason: .stop, gracefulTimeoutMs: graceMs)
    }
    // Not on a cancelled watcher: the wait exists only to hold this bracket over the worker's
    // disconnect, and `waitForWorkerExit` polls through a `Task.sleep` that stops sleeping once
    // cancelled -- it would spin its whole budget while the daemon is trying to shut down.
    if !Task.isCancelled { _ = await waitForWorkerExit(id: id, graceMs: graceMs) }
    return true
  }

  /// The profile's `timeouts.vmBoot`, or the documented default when the profile row or its decoded
  /// config is gone (a VM outlives a profile the operator removed). Same lookup shape as
  /// `gracefulShutdownMs(for:)` and `agentReadyTimeout`.
  func vmBootTimeout(for record: InstanceRecord) async -> Duration {
    guard let rows = try? await profiles.list(),
          let row = rows.first(where: { $0.id == record.profileId }),
          let config = try? row.decodedConfig()
    else { return TimeoutPolicy.default.vmBoot.duration }
    return config.effectiveTimeouts.vmBoot.duration
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
      return try await supervisor.start(
        instance: record, specPath: specPath,
        gracefulShutdownMs: await gracefulShutdownMs(for: record))
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
