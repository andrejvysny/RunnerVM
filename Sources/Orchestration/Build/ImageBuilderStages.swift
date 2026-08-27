import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Metrics
import Persistence
import RunnerCore

/// The build stage ladder: resolve → stage → boot → provision → seal.
///
/// Written as an outcome handler (`runStages` throws, `finish` unwinds) rather than a `defer`
/// chain: teardown has to `await` -- shutting the worker down, waiting for its lock, writing the
/// terminal row -- and `defer` cannot (B4).
extension ImageBuilder {
  /// Takes the id rather than the `BuildRun`: the run is mutable, non-`Sendable` actor state, so
  /// the owning `Task`'s closure may only carry its key.
  func execute(_ id: ImageBuildID) async {
    guard let run = runs[id] else { return }
    do {
      run.outcome = .success(try await runStages(run))
    } catch {
      // A cancelled build surfaces as whatever the stage it was in happened to throw -- a torn
      // exec stream reads as `transportClosed`, not `CancellationError` -- so the task's own
      // cancellation flag, not the error's type, decides that this was a cancellation.
      run.outcome = .failure(Task.isCancelled ? CancellationError() : error)
    }
    // Teardown deliberately runs in a fresh unstructured task: `cancel` cancels *this* one, and a
    // cancelled task cannot write to GRDB -- the terminal row would never land and the build would
    // sit in `provisioning` forever.
    await Task { await self.finish(id) }.value
  }

  private func runStages(_ run: BuildRun) async throws -> ImageDigest {
    run.log = try? BuildLogWriter(
      url: paths.buildLogFile(run.id), maxBytes: buildConfig.maxLogBytes)
    await run.log?.line("=== build \(run.id.rawValue) (\(run.input.name ?? "-"))")
    await hook(.queued, run.id)
    try await transition(run, to: .resolving) { $0.startedAt = .now }
    await hook(.resolvingBase, run.id)
    let base = try await resolveBase(run)
    try await transition(run, to: .staging) { record in
      record.baseDigest = base.imageDigest
      record.baseSHA256 = base.sha256
    }
    await hook(.staging, run.id)
    try await stage(run, base: base)
    try await transition(run, to: .booting)
    try await boot(run)
    try await transition(run, to: .provisioning)
    try await provision(run)
    try await transition(run, to: .sealing)
    await hook(.sealing, run.id)
    return try await sealAndRegister(run, base: base)
  }

  func transition(
    _ run: BuildRun, to state: ImageBuildState,
    mutate: @escaping @Sendable (inout ImageBuildRecord) -> Void = { _ in }
  ) async throws {
    try Task.checkCancellation()
    _ = try await builds.transition(id: run.id, from: run.state, to: state) { record in
      record.updatedAt = .now
      mutate(&record)
    }
    run.state = state
  }

  // MARK: - resolveBase

  private func resolveBase(_ run: BuildRun) async throws -> ResolvedBase {
    switch run.input.plan.from.source {
    case let .localImage(reference):
      return try await localBase(run, reference: reference)
    case let .registry(reference):
      // Pull first so the digest exists locally; `reserve` then pins exactly what was fetched.
      _ = try await images.pull(reference: reference, purpose: .buildBase)
      return try await localBase(run, reference: reference)
    case let .cloudImage(location, sha256):
      await run.log?.line("--- fetching base image \(location)")
      let fetched = try await baseFetcher().fetch(
        location: location, sha256: sha256, noCache: run.input.noCache)
      run.baseSHA256 = fetched.sourceSHA256
      run.baseRawSHA256 = fetched.rawSHA256
      run.baseSource = fetched.source
      return ResolvedBase(
        content: .rawDisk(fetched.raw, virtualBytes: fetched.virtualBytes),
        specDigest: ImageDigest(rawValue: fetched.rawSHA256), reference: location,
        source: fetched.source, sha256: fetched.sourceSHA256, rawSHA256: fetched.rawSHA256,
        needsSeed: true)
    }
  }

  /// A derived build inherits the parent's guest agent; without one the builder could never reach
  /// the VM it just booted, so this is refused before anything is cloned (spec §58).
  private func localBase(_ run: BuildRun, reference: String) async throws -> ResolvedBase {
    let (digest, info) = try await images.reserve(reference: reference, forBuild: run.id)
    run.basePinned = true
    run.baseDigest = digest
    guard info.metadata.os == .linux, info.metadata.hasGuestAgent else {
      throw ImageBuildError.baseNoGuestAgent(reference: reference)
    }
    run.baseSHA256 = digest.rawValue
    return ResolvedBase(
      content: .image(digest, info), specDigest: digest, reference: reference, source: nil,
      sha256: digest.rawValue, rawSHA256: nil, needsSeed: false)
  }

  // MARK: - stage

  private func stage(_ run: BuildRun, base: ResolvedBase) async throws {
    let input = run.input
    let spec = InstanceSpecFile(
      id: InstanceID(rawValue: run.id.rawValue), imageDigest: base.specDigest, os: .linux,
      cpuCount: input.cpuCount, memoryBytes: input.memoryBytes, diskBytes: input.diskBytes,
      macAddress: InstanceSpecFile.randomMACAddress(), serialConsole: true,
      // Five minutes past the build's own deadline: vmworker is the backstop for a runnerd that
      // died mid-build, never the thing that decides a healthy build ran too long.
      hardDeadline: tuning.now().addingTimeInterval(Double(input.timeout.milliseconds) / 1_000 + 300))
    let layout: VMBuildLayout
    switch base.content {
    case let .image(digest, _):
      layout = try await buildStore.materialize(
        buildId: run.id, from: digest, diskBytes: input.diskBytes, spec: spec)
    case let .rawDisk(url, _):
      layout = try await buildStore.materialize(
        buildId: run.id, fromRawDisk: url, diskBytes: input.diskBytes, spec: spec)
    }
    run.layout = layout
    if input.hasContext {
      try FileManager.default.moveItem(
        at: paths.buildDir(run.id).appending(path: VMInstanceLayout.contextName),
        to: layout.context)
    }
    guard base.needsSeed else { return }
    let agent = try BuildSeed.resolveAgent(config: buildConfig, paths: paths)
    try await BuildSeed.write(
      into: layout, agent: agent, runnerSudo: input.runnerSudo,
      staging: paths.buildDir(run.id).appending(path: ".seed", directoryHint: .isDirectory),
      runner: tuning.processRunner)
  }

  // MARK: - boot

  private func boot(_ run: BuildRun) async throws {
    guard let layout = run.layout else { throw ImageBuildError.interrupted }
    let worker = BuilderWorker(
      options: BuilderWorker.Options(
        buildId: run.id, specPath: layout.spec, socketDir: paths.buildSocketDir,
        socket: paths.buildWorkerSocket(run.id), logPath: layout.workerLog,
        leaseTTLMs: tuning.worker.leaseTTLMs, leaseInterval: tuning.worker.leaseInterval,
        callDeadline: tuning.worker.callDeadline,
        socketPollInterval: tuning.worker.socketPollInterval,
        socketPollAttempts: tuning.worker.socketPollAttempts),
      logger: logger)
    run.worker = worker
    await hook(.launchingWorker, run.id)
    let pid = try await worker.launch(launcher: launcher)
    try await builds.setWorker(id: run.id, pid: pid, nonce: await worker.nonce)
    await hook(.bootingGuest, run.id)
    _ = try await worker.startVM()

    let agent = GuestAgentClient(socketPath: paths.buildAgentSocket(run.id))
    run.agent = agent
    await hook(.guestBootstrap, run.id)
    do {
      // Hello only: `agent.health` stays degraded until the recipe installs the runner, so a
      // readiness gate here would deadlock every bootstrap build (B1).
      _ = try await agent.waitUntilReachable(
        timeout: tuning.agentReachableTimeout, policy: tuning.agentReadiness)
    } catch {
      throw ImageBuildError.agentUnreachable(
        reason: "\(Self.describe(error)); last serial console output:\n"
          + Self.tail(of: layout.serialLog))
    }
  }

  // MARK: - provision

  private func provision(_ run: BuildRun) async throws {
    let plan = run.input.plan
    if run.input.hasContext {
      _ = try await exec(
        run, display: "mount build context", argv: ["/bin/sh", "-c", BuildScripts.mountContext],
        env: nil, cwd: nil, step: 0, timeout: run.input.stepTimeout, capture: false)
    }
    var progress = 0
    for step in plan.steps {
      try Task.checkCancellation()
      guard ContinuousClock.now < run.deadline else { throw ImageBuildError.timeout }
      if !step.isSynthetic { progress += 1 }
      let index = progress
      await hook(Self.phase(of: step), run.id)
      try await builds.recordProgress(
        id: run.id, step: index, total: plan.totalSteps, instruction: step.display)
      await run.log?.line("--- [\(index)/\(plan.totalSteps)] \(step.display)")
      let startedAt = ContinuousClock.now
      let outcome = try await exec(
        run, display: step.display, argv: step.execArgv(contextRoot: BuildScripts.contextRoot),
        env: step.env, cwd: step.workdir, step: index,
        timeout: Self.stepTimeout(step, fallback: run.input.stepTimeout), capture: false)
      await metrics.observe(
        RunnerVMMetrics.imageBuildStepSeconds,
        labels: [RunnerVMMetrics.instructionLabel: Self.instruction(step)], since: startedAt)
      guard outcome.exitCode == 0 else {
        throw ImageBuildError.stepFailed(
          step: index, line: step.display, exitCode: outcome.exitCode,
          tail: outcome.tail.joined(separator: "\n"))
      }
    }
  }

  /// One `agent.exec`, streamed into `build.log` under the log cap, an idle timeout and the build's
  /// absolute deadline.
  @discardableResult
  func exec(
    _ run: BuildRun, display: String, argv: [String], env: [String: String]?, cwd: String?,
    step: Int, timeout: Duration, capture: Bool
  ) async throws -> StepOutcome {
    guard let agent = run.agent, let log = run.log else { throw ImageBuildError.interrupted }
    let request = ExecRequest(
      argv: argv, cwd: cwd, env: env,
      // The agent clamps at 30 minutes anyway; asking for more would silently mean 30.
      timeoutMs: min(timeout.components.seconds, 1_799) * 1_000,
      maxOutputBytes: tuning.maxOutputBytesPerStep)
    let stream = try await agent.exec(request)
    return try await BuildExecPump.run(
      stream: stream, log: log, step: step, capture: capture, idleTimeout: timeout,
      deadline: run.deadline, pollInterval: tuning.pumpPollInterval)
  }

  // MARK: - sealAndRegister

  private func sealAndRegister(_ run: BuildRun, base: ResolvedBase) async throws -> ImageDigest {
    guard let layout = run.layout, let agent = run.agent, let worker = run.worker else {
      throw ImageBuildError.interrupted
    }
    do {
      // Now the full production gate: an image whose runner never installed would boot into a VM
      // that can never take a job (B1).
      _ = try await agent.waitUntilReady(
        timeout: tuning.agentReadyTimeout, policy: tuning.agentReadiness)
    } catch {
      throw ImageBuildError.imageNotReady(reasons: [Self.describe(error)])
    }
    let probe = try await exec(
      run, display: "probe", argv: ["/bin/sh", "-c", BuildScripts.probe], env: nil, cwd: nil,
      step: run.input.plan.totalSteps, timeout: tuning.probeTimeout, capture: true)
    guard probe.exitCode == 0 else { throw ImageBuildError.probeFailed }
    let report = try BuildProbeReport.parse(probe.stdout)
    run.probeReport = report

    let sealed = try await exec(
      run, display: "seal", argv: ["/bin/sh", "-c", BuildScripts.seal], env: nil, cwd: nil,
      step: run.input.plan.totalSteps, timeout: tuning.sealTimeout, capture: false)
    guard sealed.exitCode == 0 else {
      throw ImageBuildError.sealFailed(reason: sealed.tail.joined(separator: "\n"))
    }
    try? await agent.shutdown()
    await agent.close()
    run.agent = nil
    await worker.shutdown(gracefulTimeoutMs: tuning.gracefulShutdownMs)
    run.worker = nil
    guard await BuilderWorker.waitForExit(
      lock: layout.workerLock, interval: tuning.workerExitPollInterval,
      attempts: tuning.workerExitPollAttempts)
    else {
      throw ImageBuildError.sealFailed(reason: "vmworker still holds \(layout.workerLock.lastPathComponent)")
    }
    await run.log?.line("--- sealing image")
    await hook(.storeCommit, run.id)
    let managed = try await images.sealBuild(
      directory: layout.directory, metadata: metadata(run, base: base, probe: report),
      name: run.input.name)
    // Before the directory is deleted, so a crash here leaves a `sealing` row recovery can replay
    // from the store rather than a build that silently produced nothing (B4).
    try await builds.setImageDigest(id: run.id, managed.record.digest)
    run.imageDigest = managed.record.digest
    return managed.record.digest
  }

  // MARK: - Helpers

  private static func stepTimeout(_ step: BuildStep, fallback: Duration) -> Duration {
    guard let seconds = step.timeoutSeconds else { return fallback }
    return .seconds(seconds)
  }

  /// Which fault-injection phase one provisioning step belongs to. A `WORKDIR`'s synthetic `mkdir`
  /// is a `RUN` like any other as far as a crash is concerned.
  private static func phase(of step: BuildStep) -> BuildPhase {
    switch step.action {
    case .run: .provisioningRun
    case .copy: .provisioningCopy
    }
  }

  /// The instruction keyword, so `runnervm_image_build_step_seconds` groups by RUN/COPY rather than
  /// by whatever text the recipe happened to contain.
  private static func instruction(_ step: BuildStep) -> String {
    switch step.action {
    case .run: step.isSynthetic ? "WORKDIR" : "RUN"
    case .copy: "COPY"
    }
  }

  static func describe(_ error: any Error) -> String {
    guard let error = error as? any RunnerError else { return String(describing: error) }
    return "\(error.code): \(error.message)"
  }

  /// Last lines of the serial console, which is the only window into a guest that never got far
  /// enough to answer on vsock.
  static func tail(of url: URL, lines: Int = 40) -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      return "(no serial console output)"
    }
    return text.components(separatedBy: "\n").suffix(lines).joined(separator: "\n")
  }
}
