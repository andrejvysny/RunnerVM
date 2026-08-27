import DaemonAPI
import Darwin
import Foundation
import ImageBuild
import ImageStore
import Persistence
import RunnerCore
import Scheduler

/// The synchronous half of `image.build`: everything that must be settled while the caller is still
/// on the wire, so a bad recipe, an unsafe context or a full host is an error the operator sees
/// instead of a build row that fails a second later (plan stage 1).
extension ImageBuilder {
  // MARK: - Recipe intake

  /// A directory means "the recipe file inside it"; a file is taken as written.
  static func resolveRecipePath(_ requested: String, fileName: String) throws -> URL {
    let url = URL(fileURLWithPath: requested)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
    else {
      throw ImageBuildError.recipeUnreadable(path: url.path(percentEncoded: false), uid: geteuid())
    }
    return isDirectory.boolValue ? url.appending(path: fileName) : url
  }

  /// `BUILD_RECIPE_UNREADABLE` names the path *and* the daemon's uid: under a LaunchDaemon the
  /// answer is almost always "the file is under a home directory `_runnervm` cannot traverse", and
  /// the uid is what makes that diagnosable from the error alone.
  static func parse(_ url: URL) throws -> Recipe {
    let path = url.path(percentEncoded: false)
    guard let data = FileManager.default.contents(atPath: path) else {
      throw ImageBuildError.recipeUnreadable(path: path, uid: geteuid())
    }
    return try RecipeParser.parse(
      String(decoding: data, as: UTF8.self), path: path, sha256: SHA256Digest.bytes(data))
  }

  // MARK: - Input assembly

  func makeInput(
    id: ImageBuildID, name: String, request: ImageBuildRequest, recipe: Recipe, plan: RecipePlan,
    resolved: ResolvedBuildArgs, config: ImageBuildConfig
  ) async throws -> BuildInput {
    let recipeDirectory = URL(fileURLWithPath: recipe.path).deletingLastPathComponent()
    let context = request.contextPath.map { URL(fileURLWithPath: $0) } ?? recipeDirectory
    let diskBytes = request.diskBytes ?? recipe.from.diskBytes ?? config.diskBytes
    let packed = try await packContext(id: id, plan: plan, context: context, config: config)
    let timeout = request.timeoutMs.map { Duration.milliseconds($0) } ?? config.timeout.duration
    return BuildInput(
      id: id, name: name, recipe: recipe, plan: plan,
      contextPath: context.path(percentEncoded: false), packed: packed, args: resolved.args,
      digestSource: resolved.digestSource, runnerVersion: resolved.runnerVersion,
      runnerSHA256: resolved.runnerSHA256, runnerSudo: Self.runnerSudo(resolved.args),
      cpuCount: request.cpus ?? config.cpuCount,
      memoryBytes: request.memoryBytes ?? config.memoryBytes, diskBytes: diskBytes,
      reservationBytes: reservation(
        diskBytes: diskBytes, packed: packed, plan: plan, config: config, noCache: request.noCache),
      timeout: timeout, stepTimeout: config.stepTimeout.duration, push: request.push,
      noCache: request.noCache)
  }

  /// Packed here, not in the build task: the moment this RPC answers the operator's tree is theirs
  /// again, and `context_sha256` has to describe what the build will actually see (N2).
  private func packContext(
    id: ImageBuildID, plan: RecipePlan, context: URL, config: ImageBuildConfig
  ) async throws -> PackedContext? {
    guard plan.steps.contains(where: { if case .copy = $0.action { true } else { false } })
    else { return nil }
    let ignoreFile = context.appending(path: RecipeIgnore.fileName)
    let ignore = RecipeIgnore.parse(
      (try? String(contentsOf: ignoreFile, encoding: .utf8)) ?? "")
    let directory = paths.buildDir(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      return try await BuildContextPacker.pack(
        context: context, ignore: ignore,
        into: directory.appending(path: VMInstanceLayout.contextName),
        maxBytes: config.maxContextBytes,
        staging: directory.appending(path: ".pack", directoryHint: .isDirectory),
        runner: tuning.processRunner)
    } catch {
      // Nothing else exists for this id yet, so the failed attempt leaves no directory behind.
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Worst case for the whole build, not just the guest disk (N3): the clone, two copies of the
  /// context (packed on the host, cloned into the VM directory), a cloud base that still has to be
  /// downloaded *and* converted, the log cap, and -- on a host with no clone-capable volume -- a
  /// second full disk for the sealing copy.
  private func reservation(
    diskBytes: UInt64, packed: PackedContext?, plan: RecipePlan, config: ImageBuildConfig,
    noCache: Bool
  ) -> UInt64 {
    var total = diskBytes + config.maxLogBytes
    total += (packed?.bytes ?? 0) * 2
    if case let .cloudImage(_, sha256) = plan.from.source,
       noCache || !baseImageCached(sha256: sha256) {
      total += tuning.assumedBaseImageBytes * 2
    }
    if allowFullCopy { total += diskBytes }
    return total
  }

  /// Both files, not just the disk: a raw with no sidecar is a leftover the cache sweeps rather
  /// than a hit, so a reservation that assumed otherwise would under-book the download.
  private func baseImageCached(sha256: String) -> Bool {
    let key = BaseImageCache.normalize(sha256)
    return ["raw", "json"].allSatisfy {
      FileManager.default.fileExists(
        atPath: baseCacheDirectory.appending(path: "base-\(key).\($0)").path(percentEncoded: false))
    }
  }

  /// `RUNNER_SUDO` is the one build argument the *seed* consumes rather than the recipe, so it is
  /// read here rather than interpolated into a step.
  private static func runnerSudo(_ args: [String: String]) -> Bool {
    guard let raw = args[BuildArgResolver.sudoArg]?.lowercased() else { return true }
    return !["no", "false", "0", "off"].contains(raw)
  }

  // MARK: - Row

  func makeRecord(input: BuildInput, recipe: Recipe, plan: RecipePlan) -> ImageBuildRecord {
    let from = BuildMapping.from(plan.from.source)
    var baseSHA256: String?
    if case let .cloudImage(_, sha256) = plan.from.source { baseSHA256 = sha256 }
    return ImageBuildRecord(
      id: input.id, hostId: hostId, name: input.name, state: .queued,
      pushReference: input.push, recipePath: recipe.path, recipeSHA256: recipe.sha256,
      contextPath: input.contextPath, contextSHA256: input.packed?.sha256,
      argsJson: BuildMapping.argsJSON(input.args), fromKind: from.kind,
      fromReference: from.reference, baseSHA256: baseSHA256, cpuCount: input.cpuCount,
      memoryBytes: input.memoryBytes, diskBytes: input.diskBytes,
      diskReservationBytes: input.reservationBytes,
      timeoutMs: input.timeout.milliseconds,
      buildPath: paths.buildDir(input.id).path(percentEncoded: false),
      logPath: paths.buildLogFile(input.id).path(percentEncoded: false),
      totalSteps: plan.totalSteps, createdAt: .now, updatedAt: .now)
  }

  // MARK: - Admission

  /// The capacity critical section (B3). Concurrency gate, free space, host budget and the two
  /// inserts all happen with nothing else admitted in between, so two builds -- or a build and a
  /// `vm create` -- can never both be admitted against the same snapshot.
  func admit(
    record: ImageBuildRecord, operation: OperationRecord, input: BuildInput
  ) async throws {
    let builds = builds
    let paths = paths
    let instances = instances
    let profiles = profiles
    let probe = probe
    let configuration = configuration
    let reserve = reserveDiskBytes
    let limit = max(1, buildConfig.maxConcurrent)
    do {
      try await admissionQueue.admit {
        let rows = try await builds.list(states: nil).filter { $0.state.consumesCapacity }
        guard rows.count < limit else { throw ImageBuildError.atMaxConcurrent(limit: limit) }
        try DiskAccounting.hostFreeSpaceCheck(
          paths: paths, reserveBytes: reserve, needed: input.reservationBytes)
        let reservations = try await InstanceAdmission.reservations(
          instances: instances, profiles: profiles,
          builds: RepositoryBuildReservations(builds: builds))
        let request = ResourceRequest(
          guestOS: .linux, cpuCount: input.cpuCount, memoryBytes: input.memoryBytes,
          diskReservationBytes: input.reservationBytes)
        let budget = InstanceAdmission.budget(
          configuration: configuration, probe: probe, paths: paths)
        if case let .rejected(reasons) = CapacityCalculator.fits(
          request: request, reservations: reservations, budget: budget) {
          if let error = reasons.compactMap(\.schedulerError).first { throw error }
          throw OrchestrationError.capacityRejected(reasons: reasons.map { "\($0)" })
        }
        try await builds.create(record, operation: operation)
      }
    } catch {
      // The row never landed, so nothing will ever clean this up but us.
      try? FileManager.default.removeItem(at: paths.buildDir(input.id))
      throw error
    }
  }
}
