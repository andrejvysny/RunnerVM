import Foundation
import GuestControl
import ImageStore
import Persistence
import RunnerCore

/// Cold-boot qualification of a just-sealed macOS image, run inside the build task that sealed it
/// and while that build still holds its reservation.
///
/// It is deliberately a *clone with a fresh machine identity*, not the VM that was just
/// provisioned: the image has to prove it boots as an ordinary instance would boot it. A new build
/// id gives it a directory of its own, which is what makes vmworker mint a new
/// `machine-identifier.bin` instead of reusing the builder's, its own worker socket, and its own
/// guest-agent bridge.
///
/// Four gates, in the order they can fail cheapest-first
/// (`docs/design/distribution.md`, "Build → qualify → promote", step 3):
/// the guest agent answers and reports ready; `sw_vers` runs; `agent.selfTest` is all-ok (the CI
/// keychain); and SSH is *closed*, proving the seal-time lockdown survived a reboot rather than
/// merely having been applied once.
///
/// Any failure fails the build. The sealed digest stays recorded on the build row and is reported
/// to the managed track as an unpromoted candidate; the promoted image is never touched.
extension ImageBuilder {
  func qualifyMacOS(_ run: BuildRun, candidate: ImageDigest) async throws {
    await run.log?.line("--- qualifying \(candidate.rawValue) from a cold boot")
    do {
      let address = try await bootQualification(run, candidate: candidate)
      try await checkQualificationGuest(run)
      try await requireSSHClosed(run, address: address)
    } catch let error as ImageBuildError {
      throw error
    } catch {
      throw ImageBuildError.macosQualificationFailed(reason: Self.describe(error))
    }
    await tearDownQualification(run)
    await run.log?.line("--- qualified")
  }

  // MARK: - Boot

  /// Clones the sealed image into a second VM directory and boots it. Returns the address its
  /// fresh MAC was leased, so the SSH gate can probe the guest that actually came up.
  private func bootQualification(
    _ run: BuildRun, candidate: ImageDigest
  ) async throws -> String {
    let info = try await imageStore.inspect(digest: candidate)
    let qualifyId = ImageBuildID.generate()
    run.qualifyId = qualifyId
    // Registered before the directory exists: `sweepOrphanDirectories` deletes any `builds/<id>`
    // with no row behind it, and this one deliberately has none.
    qualifying.insert(qualifyId)
    let macAddress = InstanceSpecFile.randomMACAddress()
    let diskBytes = Self.macOSDiskBytes(info)
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: qualifyId.rawValue), imageDigest: candidate, os: .macos,
      cpuCount: run.input.cpuCount, memoryBytes: run.input.memoryBytes, diskBytes: diskBytes,
      macAddress: macAddress, serialConsole: true,
      hardDeadline: tuning.now()
        .addingTimeInterval(Self.seconds(tuning.macosQualifyTimeout) + 300),
      macos: try InstanceManager.macOSPlatform(image: info))
    let layout = try await buildStore.materialize(
      buildId: qualifyId, from: candidate, diskBytes: diskBytes, spec: spec)
    run.qualifyLayout = layout

    let worker = try await launchWorker(run, id: qualifyId, layout: layout, recordOnRow: false)
    run.qualifyWorker = worker
    _ = try await worker.startVM()
    let leases = tuning.dhcpLeases
    return try await DHCPLeaseResolver.wait(
      macAddress: macAddress, timeout: tuning.macosLeaseTimeout,
      interval: tuning.macosLeasePollInterval,
      reader: leases)
  }

  // MARK: - Guest gates

  /// Agent reachable → agent ready → `sw_vers` → `agent.selfTest`.
  ///
  /// `waitUntilReady` (not just `waitUntilReachable`, as the Runnerfile ladder's boot uses): this
  /// image is finished, so an agent that reports anything short of ready is a defect in what was
  /// just sealed rather than a build still in progress.
  private func checkQualificationGuest(_ run: BuildRun) async throws {
    guard let qualifyId = run.qualifyId, let log = run.log else {
      throw ImageBuildError.interrupted
    }
    let agent = GuestAgentClient(socketPath: paths.buildAgentSocket(qualifyId))
    run.qualifyAgent = agent
    do {
      _ = try await agent.waitUntilReachable(
        timeout: tuning.macosQualifyTimeout, policy: tuning.agentReadiness)
      _ = try await agent.waitUntilReady(
        timeout: tuning.agentReadyTimeout, policy: tuning.agentReadiness)
    } catch {
      throw ImageBuildError.macosQualificationFailed(
        reason: "the guest agent never became ready: \(Self.describe(error))")
    }
    let version = try await execQualification(
      run, agent: agent, log: log, display: "sw_vers -productVersion",
      argv: ["/usr/bin/sw_vers", "-productVersion"])
    guard version.exitCode == 0 else {
      throw ImageBuildError.macosQualificationFailed(
        reason: "sw_vers exited \(version.exitCode): \(version.tail.joined(separator: "\n"))")
    }
    let reported = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    await log.line("--- guest reports macOS \(reported)")

    let selfTest: SelfTestResult
    do {
      selfTest = try await agent.selfTest()
    } catch {
      throw ImageBuildError.macosQualificationFailed(
        reason: "agent.selfTest failed: \(Self.describe(error))")
    }
    guard selfTest.passed else {
      let failed = selfTest.checks.filter { !$0.ok }
        .map { "\($0.name): \($0.detail.isEmpty ? "failed" : $0.detail)" }
      throw ImageBuildError.macosQualificationFailed(
        reason: "agent.selfTest reported \(failed.joined(separator: "; "))")
    }
  }

  private func execQualification(
    _ run: BuildRun, agent: GuestAgentClient, log: BuildLogWriter, display: String, argv: [String]
  ) async throws -> StepOutcome {
    await log.line("--- [qualify] \(display)")
    let stream = try await agent.exec(
      ExecRequest(
        argv: argv, timeoutMs: 60_000, maxOutputBytes: tuning.maxOutputBytesPerStep))
    return try await BuildExecPump.run(
      stream: stream, log: log, step: 0, capture: true, idleTimeout: .seconds(60),
      deadline: run.deadline, pollInterval: tuning.pumpPollInterval)
  }

  // MARK: - SSH gate

  /// The image must not answer on 22. "Close, don't ask": an image that still accepts the base
  /// image's well-known `admin`/`admin` credential is the exact failure the seal-time lockdown
  /// exists to prevent, and an unqualified image is never promoted (spec: distribution.md).
  private func requireSSHClosed(_ run: BuildRun, address: String) async throws {
    let timeout = tuning.macosSSHProbeTimeout
    let open = tuning.sshProbe(address, 22, timeout)
    await run.log?.line("--- ssh probe \(address):22 -> \(open ? "open" : "closed")")
    guard !open else {
      throw ImageBuildError.macosQualificationFailed(
        reason: "SSH is still reachable at \(address):22 after a cold boot; the seal-time "
          + "lockdown did not survive a reboot")
    }
  }

  // MARK: - Teardown

  /// Idempotent, and also called from `finish`'s teardown so a qualification that threw halfway
  /// still leaves no VM, no socket and no directory behind.
  func tearDownQualification(_ run: BuildRun) async {
    if let agent = run.qualifyAgent {
      try? await agent.shutdown()
      await agent.close()
      run.qualifyAgent = nil
    }
    if let worker = run.qualifyWorker {
      await worker.shutdown(gracefulTimeoutMs: tuning.gracefulShutdownMs)
      run.qualifyWorker = nil
    }
    guard let qualifyId = run.qualifyId else { return }
    var released = true
    if let layout = run.qualifyLayout {
      released = await BuilderWorker.waitForExit(
        lock: layout.workerLock, interval: tuning.workerExitPollInterval,
        attempts: tuning.workerExitPollAttempts)
    }
    try? FileManager.default.removeItem(at: paths.buildWorkerSocket(qualifyId))
    try? FileManager.default.removeItem(at: paths.buildAgentSocket(qualifyId))
    guard released else {
      // Left for `sweepOrphanDirectories`, which removes it once the lock is free. Deleting a disk
      // a live vmworker may still be writing is exactly what the lock exists to prevent.
      logger.warning(
        "qualification directory left in place: a vmworker still holds its lock",
        metadata: [
          "build_id": .string(run.id.rawValue), "qualify_id": .string(qualifyId.rawValue),
        ])
      return
    }
    try? await buildStore.delete(buildId: qualifyId)
    try? FileManager.default.removeItem(at: paths.buildDir(qualifyId))
    qualifying.remove(qualifyId)
    run.qualifyId = nil
    run.qualifyLayout = nil
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
