import DaemonAPI
import Foundation
import ImageBuild
import ImageStore
import Metrics
import Persistence
import RunnerCore

/// Everything that has to happen exactly once per build, whatever the stage ladder did: take the
/// VM down, release what was reserved, publish the terminal row, and only then start the optional
/// push (N4 -- a build is `succeeded` at seal, never at push).
extension ImageBuilder {
  func finish(_ id: ImageBuildID) async {
    guard let run = runs[id], let outcome = run.outcome else { return }
    let state = Self.terminalState(for: outcome)
    await teardown(run)
    do {
      try await terminate(
        try await require(run.id), state: state, error: outcome.failure,
        operationId: run.operationId)
    } catch {
      logger.error(
        "could not record the image build outcome",
        metadata: ["build_id": .string(run.id.rawValue), "error": .string("\(error)")])
    }
    await record(metrics: state, run: run)
    if state == .succeeded {
      await hook(.pushing, id)
      await startPush(run)
    }
    runs[run.id] = nil
    tasks[run.id] = nil
  }

  /// Cancellation is not a failure: `system shutdown --force` and `build cancel` both arrive as one.
  private static func terminalState(for outcome: Result<ImageDigest, any Error>) -> ImageBuildState {
    switch outcome {
    case .success: .succeeded
    case let .failure(error): error is CancellationError ? .cancelled : .failed
    }
  }

  // MARK: - Physical teardown

  private func teardown(_ run: BuildRun) async {
    if let agent = run.agent {
      try? await agent.shutdown()
      await agent.close()
      run.agent = nil
    }
    if let worker = run.worker {
      await worker.shutdown(gracefulTimeoutMs: tuning.gracefulShutdownMs)
      run.worker = nil
    }
    var lockReleased = true
    if let layout = run.layout {
      lockReleased = await BuilderWorker.waitForExit(
        lock: layout.workerLock, interval: tuning.workerExitPollInterval,
        attempts: tuning.workerExitPollAttempts)
      preserveDiagnostics(layout, id: run.id)
    }
    await run.log?.close()
    run.log = nil
    try? FileManager.default.removeItem(at: paths.buildWorkerSocket(run.id))
    try? FileManager.default.removeItem(at: paths.buildAgentSocket(run.id))
    // Never under a held lock: a live vmworker still owns these files, and unlinking its disk is
    // how a half-written image escapes into the store.
    if lockReleased {
      try? await buildStore.delete(buildId: run.id)
      try? FileManager.default.removeItem(at: paths.buildDir(run.id))
    } else {
      logger.warning(
        "build directory left in place: a vmworker still holds its lock",
        metadata: ["build_id": .string(run.id.rawValue)])
    }
    if run.basePinned { try? await images.release(build: run.id) }
  }

  /// `serial.log` and `worker.log` outlive the build directory, mirroring `instanceLogsDir`:
  /// `build.log` is already written straight into the log directory, so only these two move.
  private func preserveDiagnostics(_ layout: VMBuildLayout, id: ImageBuildID) {
    let destination = paths.buildLogDir(id)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for source in [layout.serialLog, layout.workerLog] {
      guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
        continue
      }
      let target = destination.appending(path: source.lastPathComponent)
      try? FileManager.default.removeItem(at: target)
      try? FileManager.default.moveItem(at: source, to: target)
    }
  }

  // MARK: - Row

  /// Moves a build row to its terminal state and closes the operation behind it. Shared by the
  /// stage ladder, `cancel` on a row nobody owns, and restart recovery.
  func terminate(
    _ record: ImageBuildRecord, state: ImageBuildState, error: (any Error)?,
    operationId: OperationID? = nil
  ) async throws {
    guard !record.state.isTerminal else { return }
    let failure = error.map(BuildMapping.failure)
    _ = try await builds.transition(id: record.id, from: record.state, to: state) { row in
      row.failureCode = failure?.code
      row.failureMessage = failure?.message
      row.finishedAt = .now
      row.updatedAt = .now
      row.workerPid = nil
    }
    guard let operation = operationId ?? record.operationId else { return }
    try? await operations.finish(
      id: operation, state: state == .succeeded ? .succeeded : .failed,
      errorCode: failure?.code, errorMessage: failure?.message)
  }

  private func record(metrics state: ImageBuildState, run: BuildRun) async {
    let labels = [RunnerVMMetrics.resultLabel: state.rawValue]
    await metrics.increment(RunnerVMMetrics.imageBuildsTotal, labels: labels)
    await metrics.observe(
      RunnerVMMetrics.imageBuildSeconds, labels: labels, since: run.startedAt)
    logger.info(
      "image build finished",
      metadata: [
        "build_id": .string(run.id.rawValue), "result": .string(state.rawValue),
        "image_digest": .string(run.imageDigest?.rawValue ?? "-"),
      ])
  }

  /// The build is already terminal (N4): a push that fails afterwards is visible through its own
  /// `push-image` operation and never retroactively fails the image that was sealed.
  private func startPush(_ run: BuildRun) async {
    guard let reference = run.input.push, let digest = run.imageDigest else { return }
    do {
      let started = try await images.startPush(imageRef: digest.rawValue, to: reference)
      guard let operation = started.operationId else { return }
      try await builds.setPushOperation(id: run.id, operation)
    } catch {
      logger.warning(
        "could not start the image push for a finished build",
        metadata: [
          "build_id": .string(run.id.rawValue), "reference": .string(reference),
          "error": .string(Self.describe(error)),
        ])
    }
  }

  // MARK: - Metadata

  /// What the guest actually turned out to be (`BuildProbeReport`), not what the recipe asked for,
  /// plus the inputs a rebuild would need (spec §24).
  func metadata(
    _ run: BuildRun, base: ResolvedBase, probe report: BuildProbeReport
  ) -> ImageMetadata {
    let input = run.input
    // The sealed disk's own size, never the requested one: `ImageStore.importLocal` refuses
    // metadata whose `virtualDiskSizeBytes` disagrees with the bytes it is hashing.
    let onDisk = run.layout.map { BaseImageCache.size(of: $0.disk) } ?? 0
    let diskBytes = onDisk > 0 ? onDisk : input.diskBytes
    return ImageMetadata(
      os: .linux, architecture: Self.normalizedArchitecture(report.architecture),
      virtualDiskSizeBytes: diskBytes,
      // The guest probe is authoritative; the host-resolved ARG is what the recipe actually
      // downloaded, so it is the right answer when the probe found no version file.
      runnerVersion: report.runnerVersion ?? input.runnerVersion,
      guestAgentVersion: report.guestAgentVersion, createdAt: tuning.now(),
      boot: ImageMetadata.Boot(type: .efi),
      capabilities: ImageMetadata.Capabilities(
        docker: report.dockerVersion != nil, ssh: report.sshEnabled, guestAgent: true,
        labels: input.plan.labels.isEmpty ? nil : input.plan.labels),
      provenance: provenance(run, base: base, report: report))
  }

  /// `uname -m` says `aarch64`; everything else in RunnerVM (metadata defaults, OCI platform
  /// selection, tart imports) spells the same machine `arm64`.
  private static func normalizedArchitecture(_ reported: String?) -> String {
    switch reported {
    case nil, "aarch64", "arm64": "arm64"
    case let other?: other
    }
  }

  private func provenance(
    _ run: BuildRun, base: ResolvedBase, report: BuildProbeReport
  ) -> ImageMetadata.Provenance {
    let input = run.input
    return ImageMetadata.Provenance(
      baseImage: base.needsSeed
        ? ImageMetadata.Provenance.BaseImage(
          source: base.source, sha256: base.sha256, rawSHA256: base.rawSHA256)
        : nil,
      actionsRunner: input.runnerVersion.map {
        ImageMetadata.Provenance.ActionsRunner(
          version: $0, sha256: input.runnerSHA256, digestSource: input.digestSource)
      },
      builder: ImageMetadata.Provenance.Builder(
        gitCommit: RunnerVMBuild.version, script: "runnerd image.build",
        hostOSVersion: probe.osVersion, builtAt: RFC3339.string(from: tuning.now())),
      docker: report.dockerVersion.map { ImageMetadata.Provenance.Docker(version: $0) },
      packages: report.packages.isEmpty ? nil : report.packages,
      kernelVersion: report.kernelVersion,
      recipe: ImageMetadata.Provenance.Recipe(
        path: input.recipe.path, sha256: input.recipe.sha256, from: base.reference,
        args: input.args.isEmpty ? nil : input.args),
      parentImageDigest: base.imageDigest?.rawValue)
  }
}

extension Result {
  /// The error a `Result` carries, or `nil`. Reads better than a `switch` at the two call sites
  /// that only care about the failure half.
  var failure: Failure? {
    guard case let .failure(error) = self else { return nil }
    return error
  }
}
