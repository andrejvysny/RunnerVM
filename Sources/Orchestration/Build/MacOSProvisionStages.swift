import DaemonAPI
import Foundation
import GuestControl
import ImageStore
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import WorkerProtocol

/// The `macosProvision` stage ladder (phase D7): the same six `ImageBuildState`s a Runnerfile build
/// walks, with a completely different thing happening inside each of them.
///
/// | state | Runnerfile | macosProvision |
/// | --- | --- | --- |
/// | `resolving` | resolve + pin the `FROM` base | pull the Tart export under `.provisioningBase` |
/// | `staging` | clone + cloud-init seed | clone the read-only import into a builder VM |
/// | `booting` | boot, wait on the guest agent | boot, find the guest's IP in `dhcpd_leases` |
/// | `provisioning` | `agent.exec` per recipe step | one host-side script driving SSH |
/// | `sealing` | probe, seal | seal, then cold-boot-qualify a *clone* of what was sealed |
///
/// Everything the Runnerfile ladder owns -- the transitions, the reservation, teardown, restart
/// recovery, `build log`/`build cancel` -- is shared verbatim, which is the whole reason a
/// provisioning run is an `image_builds` row rather than a mechanism of its own
/// (`docs/design/distribution.md`, "macOS provisioning runs").
extension ImageBuilder {
  func runMacOSStages(_ run: BuildRun) async throws -> ImageDigest {
    guard let macos = run.input.macos else { throw ImageBuildError.interrupted }
    try await transition(run, to: .resolving) { $0.startedAt = .now }
    await hook(.resolvingBase, run.id)
    let base = try await resolveMacOSBase(run, macos: macos)

    try await transition(run, to: .staging) { record in
      record.baseDigest = base.digest
      record.baseSHA256 = base.digest.rawValue
      record.sourceDigest = macos.sourceDigest
    }
    await hook(.staging, run.id)
    let macAddress = try await stageMacOS(run, base: base)

    try await transition(run, to: .booting)
    let address = try await bootMacOS(run, macAddress: macAddress)

    try await transition(run, to: .provisioning)
    try await driveProvisioning(run, macos: macos, address: address)

    try await transition(run, to: .sealing)
    await hook(.sealing, run.id)
    let digest = try await sealMacOS(run, base: base)
    try await qualifyMacOS(run, candidate: digest)
    return digest
  }

  // MARK: - resolving

  /// The Tart export, pulled under the one purpose that admits an agentless artifact and pinned
  /// for the length of the build.
  ///
  /// `images.reserve(reference:forBuild:)` is deliberately not used: it resolves under
  /// `.buildBase`, which refuses exactly this image. The pull and the pin are therefore done in
  /// two steps here -- the pull shares an in-flight transfer with any concurrent one, and the pin
  /// is what `image.prune` reads to leave the base alone while this build clones it.
  private func resolveMacOSBase(
    _ run: BuildRun, macos: MacOSProvisionInput
  ) async throws -> (digest: ImageDigest, info: ImageInfo) {
    await run.log?.line("--- pulling macOS base \(macos.sourceReference)")
    let record = try await images.pull(
      reference: macos.sourceReference, purpose: .provisioningBase)
    let info = try await images.pin(base: record.digest, forBuild: run.id)
    run.basePinned = true
    run.baseDigest = record.digest
    run.baseImage = info
    guard info.metadata.os == .macos else {
      throw ImageBuildError.baseFormatUnsupported(
        reason: "\(macos.sourceReference) is a \(info.metadata.os.rawValue) image; a managed "
          + "macOS source has to resolve to a macOS one")
    }
    return (record.digest, info)
  }

  // MARK: - staging

  /// Clones the read-only import into a builder VM and returns the MAC its `spec.json` names --
  /// the only handle the host has on a guest that cannot yet answer on vsock.
  private func stageMacOS(
    _ run: BuildRun, base: (digest: ImageDigest, info: ImageInfo)
  ) async throws -> String {
    let input = run.input
    // The image's own disk layer, exactly: a macOS guest can neither grow nor shrink its APFS
    // container, so `disk_bytes` is a fact about the image rather than a request (see
    // `InstanceManager.checkMacOSDiskContract`). `BuildStore.materialize` clones the `nvram`
    // layer alongside it, which a macOS guest cannot boot without.
    let diskBytes = Self.macOSDiskBytes(base.info)
    let macAddress = InstanceSpecFile.randomMACAddress()
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: run.id.rawValue), imageDigest: base.digest, os: .macos,
      cpuCount: input.cpuCount, memoryBytes: input.memoryBytes, diskBytes: diskBytes,
      macAddress: macAddress, serialConsole: true,
      hardDeadline: tuning.now()
        .addingTimeInterval(Double(input.timeout.milliseconds) / 1_000 + 300),
      macos: try InstanceManager.macOSPlatform(image: base.info))
    run.layout = try await buildStore.materialize(
      buildId: run.id, from: base.digest, diskBytes: diskBytes, spec: spec)
    return macAddress
  }

  /// The disk layer's own size, never `metadata.virtualDiskSizeBytes` (which sums every layer,
  /// auxiliary storage included, and which a hand-edited `metadata.json` can misstate). This is
  /// the number `BuildStore.materialize` measures the request against.
  static func macOSDiskBytes(_ info: ImageInfo) -> UInt64 {
    info.manifest.layer(.disk)?.sizeBytes ?? info.metadata.virtualDiskSizeBytes
  }

  // MARK: - booting

  /// Boots the builder VM and finds its address. No guest-agent wait: the whole point of this
  /// build is that the base has no agent yet, so the DHCP lease is the readiness signal.
  private func bootMacOS(_ run: BuildRun, macAddress: String) async throws -> String {
    guard let layout = run.layout else { throw ImageBuildError.interrupted }
    let worker = try await launchWorker(
      run, id: run.id, layout: layout, recordOnRow: true)
    run.worker = worker
    await hook(.bootingGuest, run.id)
    _ = try await worker.startVM()
    await run.log?.line("--- waiting for a DHCP lease for \(macAddress)")
    let leases = tuning.dhcpLeases
    do {
      let address = try await DHCPLeaseResolver.wait(
        macAddress: macAddress, timeout: tuning.macosLeaseTimeout,
        interval: tuning.macosLeasePollInterval,
        reader: leases)
      await run.log?.line("--- guest is at \(address)")
      return address
    } catch {
      // The serial console is the only other window into a guest that never got a lease, and the
      // reason it did not is almost always in it.
      throw ImageBuildError.agentUnreachable(
        reason: "\(Self.describe(error)); last serial console output:\n"
          + Self.tail(of: layout.serialLog))
    }
  }

  /// One `BuilderWorker`, launched and fenced. Shared by the provisioning VM and the qualification
  /// VM, which differ only in which id (and therefore which directory and socket) they own.
  func launchWorker(
    _ run: BuildRun, id: ImageBuildID, layout: VMBuildLayout, recordOnRow: Bool
  ) async throws -> BuilderWorker {
    let worker = BuilderWorker(
      options: BuilderWorker.Options(
        buildId: id, specPath: layout.spec, socketDir: paths.buildSocketDir,
        socket: paths.buildWorkerSocket(id), logPath: layout.workerLog,
        leaseTTLMs: tuning.worker.leaseTTLMs, leaseInterval: tuning.worker.leaseInterval,
        callDeadline: tuning.worker.callDeadline,
        socketPollInterval: tuning.worker.socketPollInterval,
        socketPollAttempts: tuning.worker.socketPollAttempts),
      logger: logger)
    await hook(.launchingWorker, run.id)
    let pid = try await worker.launch(launcher: launcher)
    // Only the provisioning VM's pid goes on the row: that is the worker restart recovery probes,
    // and the qualification VM is torn down inside the same task that created it.
    if recordOnRow {
      try await builds.setWorker(id: run.id, pid: pid, nonce: await worker.nonce)
    }
    return worker
  }

  // MARK: - provisioning

  /// Hands the running guest to `provision-macos-tart.sh --attach`, which installs the guest
  /// agent and `actions/runner` over SSH, runs the seal-time lockdown, and waits for port 22 to
  /// close. The guest then halts itself; this side watches the VM stop.
  private func driveProvisioning(
    _ run: BuildRun, macos: MacOSProvisionInput, address: String
  ) async throws {
    let work = paths.buildDir(run.id).appending(path: ".provision", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: work.path(percentEncoded: false))
    let resultPath = work.appending(path: "result.json")
    var argv = [
      "--attach", address,
      "--result", resultPath.path(percentEncoded: false),
      "--agent-binary", macos.agentBinary.path(percentEncoded: false),
      "--work", work.path(percentEncoded: false),
    ]
    if macos.debugSSH { argv.append("--debug-ssh") }
    await run.log?.line("--- \(macos.script.lastPathComponent) \(argv.joined(separator: " "))")

    // The script's output goes through a stream rather than a `Task` per line: the writes land on
    // an actor, and one unstructured task per line would let a 40-minute transcript interleave
    // itself out of order in `build.log`.
    let (lines, publish) = AsyncStream<String>.makeStream()
    let log = run.log
    let pump = Task { for await line in lines { await log?.line(line) } }
    let outcome: ProcessResult
    do {
      outcome = try await tuning.processRunner.run(
        macos.script.path(percentEncoded: false), argv, timeout: run.input.timeout,
        onOutput: { publish.yield($0) })
    } catch {
      publish.finish()
      await pump.value
      throw error
    }
    publish.finish()
    await pump.value
    // The script guarantees the result file exists whatever its exit code, so it -- not the exit
    // code -- is what says why a run failed. A missing file is itself reported as a failure.
    let result = try MacOSProvisionResult.read(resultPath)
    run.provisionResult = result
    guard outcome.exitCode == 0 || !result.ok else {
      throw ImageBuildError.macosProvisionFailed(
        reason: "the provisioning script exited \(outcome.exitCode) after reporting success")
    }
    try result.requireSealable(debugSSH: macos.debugSSH)
    try await waitForGuestStop(run)
  }

  /// The guest halts itself once the lockdown is done, so the VM reaching `stopped` on its own is
  /// the proof that the provisioning run finished cleanly rather than being cut off.
  private func waitForGuestStop(_ run: BuildRun) async throws {
    guard let worker = run.worker else { throw ImageBuildError.interrupted }
    await run.log?.line("--- waiting for the guest to power itself down")
    let deadline = ContinuousClock.now.advanced(by: tuning.macosGuestStopTimeout)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      // A transport failure means the worker already exited, which only happens after its VM
      // stopped -- the same outcome, reached from the other side.
      guard let state = try? await worker.vmState() else { return }
      if state == .stopped { return }
      try await Task.sleep(for: tuning.macosGuestStopPollInterval)
    }
    throw ImageBuildError.macosGuestDidNotStop(
      seconds: Int(tuning.macosGuestStopTimeout.components.seconds))
  }

  // MARK: - sealing

  /// Publishes the stopped builder VM's disk (and its auxiliary storage) as an image.
  ///
  /// `name: nil`, deliberately: the managed alias is what a profile resolves through, and moving
  /// it here would publish a candidate that has not been cold-boot-qualified yet. Promotion is a
  /// separate, later step (`ImageUpdateService.promote`).
  private func sealMacOS(
    _ run: BuildRun, base: (digest: ImageDigest, info: ImageInfo)
  ) async throws -> ImageDigest {
    guard let layout = run.layout, let worker = run.worker else {
      throw ImageBuildError.interrupted
    }
    await worker.shutdown(gracefulTimeoutMs: tuning.gracefulShutdownMs)
    run.worker = nil
    guard await BuilderWorker.waitForExit(
      lock: layout.workerLock, interval: tuning.workerExitPollInterval,
      attempts: tuning.workerExitPollAttempts)
    else {
      throw ImageBuildError.sealFailed(
        reason: "vmworker still holds \(layout.workerLock.lastPathComponent)")
    }
    await run.log?.line("--- sealing image")
    await hook(.storeCommit, run.id)
    // Built before the directory goes away: the metadata records the sealed disk's own size, read
    // off `layout.disk`.
    let metadata = macOSMetadata(run, base: base)
    let managed = try await images.sealBuild(
      directory: layout.directory, metadata: metadata, name: nil)
    // Before the directory is deleted, so a crash here leaves a `sealing` row recovery can replay
    // from the store rather than a build that silently produced nothing (B4).
    try await builds.setImageDigest(id: run.id, managed.record.digest)
    run.imageDigest = managed.record.digest
    releaseProvisioningVM(run, layout: layout)
    return managed.record.digest
  }

  /// Drops the provisioning VM's directory the moment the store owns its bytes, so the cold-boot
  /// qualification clone that follows reuses that space instead of needing a second macOS disk's
  /// worth of it. On a 60-100 GiB macOS image that is the difference between a run that fits on an
  /// ordinary Mac mini and one that does not, which is why it is not left to `finish`'s teardown.
  ///
  /// Clearing `run.layout` is what tells teardown there is nothing left to wait on or move.
  private func releaseProvisioningVM(_ run: BuildRun, layout: VMBuildLayout) {
    preserveDiagnostics(layout, id: run.id)
    Task { try? await buildStore.delete(buildId: run.id) }
    run.layout = nil
  }

  /// The sealed image's `metadata.json`.
  ///
  /// The platform block is the *base's*: `hardwareModel` and the boot minimums describe the restore
  /// image the disk was made from and are unchanged by anything the provisioning run did. The
  /// capabilities are this build's: an agent now exists, docker never does on macOS, and `ssh` is
  /// false precisely because the lockdown was proven (`--debug-ssh` is the one exception, and it
  /// says so in the metadata rather than hiding it).
  func macOSMetadata(
    _ run: BuildRun, base: (digest: ImageDigest, info: ImageInfo)
  ) -> ImageMetadata {
    let result = run.provisionResult
    let onDisk = run.layout.map { BaseImageCache.size(of: $0.disk) } ?? 0
    let baseMetadata = base.info.metadata
    return ImageMetadata(
      os: .macos, architecture: baseMetadata.architecture, virtualDiskSizeBytes: onDisk,
      runnerVersion: result?.runnerVersion, guestAgentVersion: result?.guestAgentVersion,
      minimumHostOS: baseMetadata.minimumHostOS, createdAt: tuning.now(),
      boot: ImageMetadata.Boot(type: .macos), macos: baseMetadata.macos,
      capabilities: ImageMetadata.Capabilities(
        docker: false, ssh: result?.ssh ?? false, guestAgent: true),
      provenance: macOSProvenance(run, base: base))
  }

  private func macOSProvenance(
    _ run: BuildRun, base: (digest: ImageDigest, info: ImageInfo)
  ) -> ImageMetadata.Provenance {
    let macos = run.input.macos
    return ImageMetadata.Provenance(
      actionsRunner: run.provisionResult?.runnerVersion.map {
        ImageMetadata.Provenance.ActionsRunner(version: $0)
      },
      guestAgent: run.provisionResult?.guestAgentVersion.map {
        ImageMetadata.Provenance.GuestAgent(reportedVersion: $0)
      },
      builder: ImageMetadata.Provenance.Builder(
        gitCommit: RunnerVMBuild.version, script: "runnerd image.provision (macosProvision)",
        hostOSVersion: probe.osVersion, builtAt: RFC3339.string(from: tuning.now())),
      // The Tart lineage the disk still carries, kept rather than replaced: this image *is* that
      // export, provisioned. `recipe.from` records which reference it was pulled from.
      imported: base.info.metadata.provenance?.imported,
      recipe: macos.map {
        ImageMetadata.Provenance.Recipe(
          path: $0.script.path(percentEncoded: false), sha256: $0.scriptSHA256,
          from: $0.sourceReference)
      },
      parentImageDigest: base.digest.rawValue)
  }
}
