import DaemonAPI
import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging
import Scheduler

/// The in-daemon image builder (spec §59-§62): `image.build` and the `build.*` family.
///
/// Owns the `Task` behind every running build rather than detaching them, which is what lets
/// `stop(cancel:)` be awaited during daemon teardown and `recover()` tell "a build this process is
/// running" apart from "a row a previous process left behind" (B4).
public actor ImageBuilder: ImageBuildService, ImageBuildReservationSource {
  public struct Tuning: Sendable {
    /// The base has no runner yet, so readiness is `waitUntilReachable` (hello only) here; full
    /// `waitUntilReady` is required before sealing instead (B1).
    public var agentReachableTimeout: Duration = .seconds(600)
    public var agentReadyTimeout: Duration = .seconds(300)
    public var agentReadiness = GuestAgentClient.ReadinessPolicy()
    /// Per-step ceiling on what the guest may stream back before the build fails (B9).
    public var maxOutputBytesPerStep: Int64 = 16 << 20
    public var gracefulShutdownMs: Int64 = 120_000
    public var sealTimeout: Duration = .seconds(600)
    public var probeTimeout: Duration = .seconds(300)
    public var workerExitPollInterval: Duration = .milliseconds(100)
    public var workerExitPollAttempts = 600
    /// How long restart recovery waits for an orphaned builder worker to release its `fcntl` lock
    /// after asking it to shut down. Far shorter than `workerExitPoll*`: `recover()` runs inside
    /// the serial reconcile tick, and a worker that outlives this is kept pending, not waited on.
    public var recoveryExitWait: (interval: Duration, attempts: Int) = (.milliseconds(100), 50)
    /// How long a build whose builder worker cannot be proven dead may keep its host capacity, its
    /// base-image pin and its directory before the row is abandoned.
    ///
    /// Must exceed the worker lease TTL (30 s) plus vmworker's own `orphanIdleMs` backstop (600 s):
    /// an orphaned vmworker self-terminates after ~630 s, and this deadline exists only for the
    /// case where even that did not happen. 15 min leaves margin over it.
    public var recoveryDeadline: Duration = .seconds(900)
    public var pumpPollInterval: Duration = .milliseconds(200)
    public var worker = BuilderWorkerDefaults()
    /// Assumed size of a cloud base before it has been downloaded, for the disk reservation (N3).
    public var assumedBaseImageBytes: UInt64 = ByteSize.gibibytes(4).bytes
    public var processRunner: any ProcessRunner = SystemProcessRunner()
    /// `nil` builds a `BaseImageCache` from the configured cache directory.
    public var baseImages: (any BaseImageFetcher)?
    /// `nil` uses `GitHubRunnerReleaseLookup` over the daemon's gateway.
    public var releases: (any RunnerReleaseLookup)?
    public var now: @Sendable () -> Date = { Date() }
    /// Fault-injection seams. Never set outside tests; see `BuildHooks`.
    public var hooks = BuildHooks()

    public init() {}
  }

  /// Timing knobs handed straight through to each `BuilderWorker`.
  public struct BuilderWorkerDefaults: Sendable {
    public var leaseTTLMs: Int64 = 30_000
    public var leaseInterval: Duration = .seconds(10)
    public var callDeadline: Duration = .seconds(30)
    public var socketPollInterval: Duration = .milliseconds(100)
    public var socketPollAttempts = 300

    public init() {}
  }

  static let operationKind = "build-image"

  let paths: RunnerPaths
  let hostId: HostID
  let builds: any ImageBuildRepository
  let imageRows: any ImageRepository
  let operations: any OperationRepository
  let images: ImageManager
  let imageStore: ImageStore
  let buildStore: BuildStore
  let launcher: any WorkerLauncher
  let probe: HostProbeResult
  let instances: any InstanceRepository
  let profiles: any ProfileRepository
  let hosts: (any HostRepository)?
  let admissionQueue: AdmissionQueue
  let runnerVersions: RunnerVersionMonitor?
  let gateway: GitHubGateway?
  let metrics: MetricRegistry
  /// Mirrors what `BuildStore` was built with: a host that falls back to a full copy needs a
  /// second disk's worth of headroom reserved for sealing (N3).
  let allowFullCopy: Bool
  let tuning: Tuning
  let logger: Logger

  var configuration: RunnerConfiguration?
  /// Built lazily and kept: the cache owns an LRU index and a one-transfer-per-digest map, both of
  /// which a per-build instance would throw away. Dropped whenever the configuration changes.
  var baseCache: BaseImageCache?
  var tasks: [ImageBuildID: Task<Void, Never>] = [:]
  var runs: [ImageBuildID: BuildRun] = [:]
  /// Set by `stop`: refuses new builds while the daemon is going down, without needing the host
  /// row to have been moved to `draining` first.
  var stopped = false

  public init(
    paths: RunnerPaths, hostId: HostID, builds: any ImageBuildRepository,
    imageRows: any ImageRepository, operations: any OperationRepository, images: ImageManager,
    imageStore: ImageStore, buildStore: BuildStore, launcher: any WorkerLauncher,
    probe: HostProbeResult, instances: any InstanceRepository, profiles: any ProfileRepository,
    hosts: (any HostRepository)? = nil, admissionQueue: AdmissionQueue,
    runnerVersions: RunnerVersionMonitor? = nil, gateway: GitHubGateway? = nil,
    metrics: MetricRegistry = MetricRegistry(), allowFullCopy: Bool = false,
    tuning: Tuning = Tuning(), logger: Logger = Logger(component: .image)
  ) {
    self.paths = paths
    self.hostId = hostId
    self.builds = builds
    self.imageRows = imageRows
    self.operations = operations
    self.images = images
    self.imageStore = imageStore
    self.buildStore = buildStore
    self.launcher = launcher
    self.probe = probe
    self.instances = instances
    self.profiles = profiles
    self.hosts = hosts
    self.admissionQueue = admissionQueue
    self.runnerVersions = runnerVersions
    self.gateway = gateway
    self.metrics = metrics
    self.allowFullCopy = allowFullCopy
    self.tuning = tuning
    self.logger = logger
  }

  public func updateConfiguration(_ config: RunnerConfiguration?) {
    configuration = config
    baseCache = nil
  }

  var buildConfig: ImageBuildConfig { configuration?.build ?? ImageBuildConfig() }

  var reserveDiskBytes: UInt64 {
    configuration?.host.reserve.diskBytes ?? HostConfig.Reserve().diskBytes
  }

  // MARK: - ImageBuildService

  public func start(_ request: ImageBuildRequest) async throws -> ImageBuildResponse {
    try await refuseWhenClosed()
    let config = buildConfig
    let recipePath = try Self.resolveRecipePath(request.recipePath, fileName: config.recipeFileName)
    let recipe = try Self.parse(recipePath)
    let resolved = try await resolver().resolve(recipe: recipe, requested: request.args)
    let plan = try RecipePlanner.plan(recipe, args: resolved.args)
    // Bounded before anything is packed or admitted: every step is an `agent.exec` against an
    // untrusted guest, and a recipe is operator input like any other.
    guard plan.totalSteps <= config.maxSteps else {
      throw ImageBuildError.tooManySteps(count: plan.totalSteps, limit: config.maxSteps)
    }
    guard let name = request.name ?? plan.imageName else { throw ImageBuildError.nameRequired }

    let id = ImageBuildID.generate()
    let input = try await makeInput(
      id: id, name: name, request: request, recipe: recipe, plan: plan, resolved: resolved,
      config: config)
    let operation = OperationRecord(
      id: OperationID.generate(), kind: Self.operationKind, resourceType: "image-build",
      resourceId: id.rawValue, state: .running, startedAt: .now)
    var record = makeRecord(input: input, recipe: recipe, plan: plan)
    // Named on the row from the first insert, so `build show` can point at the operation and
    // restart recovery can close it without having to guess which one it was.
    record.operationId = operation.id
    try await admit(record: record, operation: operation, input: input)

    let run = BuildRun(input: input)
    run.operationId = operation.id
    runs[id] = run
    tasks[id] = Task { [weak self] in await self?.execute(id) }
    logger.info(
      "image build queued",
      metadata: [
        "build_id": .string(id.rawValue), "name": .string(name),
        "from": .string(record.fromReference), "steps": .stringConvertible(plan.totalSteps),
      ])
    return ImageBuildResponse(
      buildId: id.rawValue, operationId: operation.id.rawValue, name: name,
      from: record.fromReference, totalSteps: plan.totalSteps)
  }

  public func list() async throws -> [BuildInfoDTO] {
    try await builds.list(states: nil)
      .sorted { $0.createdAt.date > $1.createdAt.date }
      .map(BuildMapping.info)
  }

  public func get(id: String) async throws -> BuildInfoDTO {
    BuildMapping.info(try await require(ImageBuildID(rawValue: id)))
  }

  /// Cancels the owned `Task`; the stage ladder unwinds through the same teardown a failure takes,
  /// so the VM, the pin and the directory are cleaned up exactly once.
  ///
  /// A row this process does not own is only cancellable once its builder worker is proven dead;
  /// otherwise it answers `BUILD_WORKER_UNVERIFIABLE` rather than silently freeing capacity a live
  /// VM is still using.
  public func cancel(id: String) async throws -> BuildCancelResponse {
    let buildId = ImageBuildID(rawValue: id)
    let record = try await require(buildId)
    guard !record.state.isTerminal else {
      throw ImageBuildError.notCancellable(state: record.state.rawValue)
    }
    if let task = tasks[buildId] {
      task.cancel()
      return BuildCancelResponse(buildId: id, state: record.state.rawValue)
    }
    // No owning task: a row this process never started (or already forgot). Nothing else will ever
    // move it -- but nothing may be released either until the builder VM behind it is proven gone,
    // so this takes exactly the same verdict restart recovery does.
    let verdict = await probeOrphan(record)
    guard verdict.isProvenDead else {
      throw ImageBuildError.buildWorkerUnverifiable(buildId: id, reason: verdict.reason)
    }
    discard(record.id)
    try await images.release(build: record.id)
    try await terminate(record, state: .cancelled, error: ImageBuildError.cancelled)
    try? await builds.setRecoverySince(id: record.id, nil)
    return BuildCancelResponse(buildId: id, state: ImageBuildState.cancelled.rawValue)
  }

  public func readLog(id: String, offset: Int64, maxBytes: Int64) async throws -> BuildLogResponse {
    let record = try await require(ImageBuildID(rawValue: id))
    let chunk = BuildLogWriter.read(
      url: URL(fileURLWithPath: record.logPath), offset: offset, maxBytes: maxBytes)
    let complete = record.state.isTerminal && chunk.data.isEmpty
    return BuildLogResponse(
      data: String(decoding: chunk.data, as: UTF8.self), nextOffset: chunk.next, done: complete)
  }

  // MARK: - Capacity

  public func activeBuildReservations() async throws -> [Reservation] {
    Self.reservations(try await builds.list(states: nil))
  }

  static func reservations(_ rows: [ImageBuildRecord]) -> [Reservation] {
    rows.filter { $0.state.consumesCapacity }.map {
      Reservation.imageBuild(
        id: $0.id.rawValue, cpuCount: $0.cpuCount, memoryBytes: $0.memoryBytes,
        diskBytes: $0.diskReservationBytes, createdAt: $0.createdAt.date)
    }
  }

  // MARK: - Lifecycle

  /// Daemon teardown. `cancel: true` (`system shutdown --force`) tears running builds down;
  /// otherwise they are waited out, bounded by their own timeout, the same way a drain waits for
  /// active sessions.
  public func stop(cancel: Bool) async {
    stopped = true
    let running = tasks
    if cancel {
      for task in running.values { task.cancel() }
    } else if !running.isEmpty {
      logger.notice(
        "waiting for image builds to finish before shutting down",
        metadata: ["builds": .stringConvertible(running.count)])
      await waitOut()
    }
    for task in running.values { await task.value }
    tasks.removeAll()
    runs.removeAll()
  }

  /// Bounded by the configured build timeout: a graceful shutdown waits a build out, but must not
  /// hang forever on a guest that stopped answering before its own deadline could fire.
  private func waitOut() async {
    let deadline = ContinuousClock.now.advanced(by: buildConfig.timeout.duration)
    while !tasks.isEmpty, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    for task in tasks.values { task.cancel() }
  }

  // MARK: - Helpers

  /// Fires a `BuildHooks` seam. A no-op in production, where `beforePhase` is `nil`.
  func hook(_ phase: BuildPhase, _ id: ImageBuildID) async {
    guard let beforePhase = tuning.hooks.beforePhase else { return }
    await beforePhase(phase, id)
  }

  func require(_ id: ImageBuildID) async throws -> ImageBuildRecord {
    guard let record = try await builds.get(id: id) else {
      throw ImageBuildError.notFound(id: id.rawValue)
    }
    return record
  }

  func resolver() -> BuildArgResolver {
    BuildArgResolver(
      lookup: tuning.releases
        ?? GitHubRunnerReleaseLookup(versions: runnerVersions, gateway: gateway))
  }

  func baseFetcher() -> any BaseImageFetcher {
    if let injected = tuning.baseImages { return injected }
    if let baseCache { return baseCache }
    let builds = self.builds
    let cache = BaseImageCache(
      directory: baseCacheDirectory, policy: buildConfig.cache, reserveBytes: reserveDiskBytes,
      pinned: { await Self.pinnedBaseKeys(builds) }, metrics: metrics, now: tuning.now,
      logger: logger)
    baseCache = cache
    return cache
  }

  var baseCacheDirectory: URL {
    buildConfig.cacheDir.map { URL(fileURLWithPath: $0) } ?? paths.baseImageCacheDir
  }

  /// Every base a build row that has not reached a terminal state still depends on. Derived from
  /// the repository rather than tracked in memory, so a daemon restart re-establishes the pins
  /// instead of leaving a resumed build's base evictable.
  static func pinnedBaseKeys(_ builds: any ImageBuildRepository) async -> Set<String> {
    guard let rows = try? await builds.list(states: nil) else { return [] }
    return Set(
      rows.lazy
        .filter { !$0.state.isTerminal }
        .compactMap(\.baseSHA256)
        .map(BaseImageCache.normalize))
  }

  /// A draining or offline host admits no new work of any kind; a daemon already tearing down
  /// admits none either.
  private func refuseWhenClosed() async throws {
    guard !stopped else {
      throw DaemonServiceError.unavailable(reason: "the daemon is shutting down")
    }
    guard let hosts, let mode = try? await hosts.mode(id: hostId), mode != .normal else { return }
    throw DaemonServiceError.unavailable(
      reason: "the host is \(mode.rawValue); image builds are not admitted "
        + "(run `runnerctl system resume` first)")
  }
}

/// Reads build reservations straight from the repository, so the admission critical section never
/// has to re-enter the `ImageBuilder` actor it is already running inside.
struct RepositoryBuildReservations: ImageBuildReservationSource {
  let builds: any ImageBuildRepository

  func activeBuildReservations() async throws -> [Reservation] {
    ImageBuilder.reservations(try await builds.list(states: nil))
  }
}
