import DaemonAPI
import Foundation
import ImageStore
import Logging
import Metrics
import Persistence
import RPC
import RunnerCore
import RunnerLogging

/// Composition root for `runnerd`: startup order per spec §69, teardown per §108.
///
/// M2 adds the image and instance managers, the worker supervisor (spawn, fencing, lease,
/// reconnect) and the reconcile steps that adopt or interrupt workers after a restart.
public actor DaemonRuntime {
  public struct Options: Sendable {
    public var paths: RunnerPaths
    /// Applied at startup when present. Absent means "adopt whatever was applied last".
    public var configPath: URL?
    public var reconcileInterval: Duration
    public var reconcileJitter: Duration
    /// Cadence of the slow maintenance loop: disk-pressure refresh and image staging sweep
    /// (spec §17, §57). Deliberately independent of `reconcileInterval` -- upkeep this cheap
    /// doesn't need the fast loop's cadence, and a five-minute default keeps it off the log
    /// unless something actually changed.
    public var maintenanceInterval: Duration
    /// `nil` resolves to `$RUNNERVM_VMWORKER` or a sibling of the running executable.
    public var vmworkerPath: URL?
    /// `nil` accepts any peer UID; runnerd restricts this to its own UID.
    public var allowedUIDs: Set<uid_t>?
    /// Test seam: `nil` spawns the real `vmworker` binary with `posix_spawn`.
    public var launcher: (any WorkerLauncher)?
    /// Recorded in `audit_events.actor`.
    public var actorName: String
    /// Test seam: `nil` talks to api.github.com through the shared `URLSession` and the login
    /// keychain.
    public var github: GitHubGateway.Options?
    /// Test seam: `nil` builds real `URLSession`-backed registry clients using the standard
    /// credential chain (env → docker config → Keychain).
    public var registries: (any RegistryClientFactory)?
    /// Which demand provider drives the orchestrator. `nil` (the default) reads
    /// `RunnerConfiguration.github.demand`; a non-nil value overrides the configuration, for
    /// tests and CLI flags. Changing this on a running daemon has no effect until it restarts —
    /// providers are wired once at startup and never hot-swapped.
    public var demandMode: DemandMode?
    /// How long `system.shutdown` waits before tearing the socket down, so the reply reaches the
    /// caller first. Tests set it to zero.
    public var shutdownDelay: Duration
    /// `false` stops the runtime without calling `exit`, which is the only way a test can drive
    /// `system.shutdown` end to end.
    public var exitOnShutdown: Bool

    public init(
      paths: RunnerPaths,
      configPath: URL? = nil,
      reconcileInterval: Duration = .seconds(10),
      reconcileJitter: Duration = .seconds(2),
      maintenanceInterval: Duration = .seconds(300),
      vmworkerPath: URL? = nil,
      allowedUIDs: Set<uid_t>? = nil,
      launcher: (any WorkerLauncher)? = nil,
      actorName: String = "runnerd",
      github: GitHubGateway.Options? = nil,
      registries: (any RegistryClientFactory)? = nil,
      demandMode: DemandMode? = nil,
      shutdownDelay: Duration = .milliseconds(200),
      exitOnShutdown: Bool = true
    ) {
      self.paths = paths
      self.configPath = configPath
      self.reconcileInterval = reconcileInterval
      self.reconcileJitter = reconcileJitter
      self.maintenanceInterval = maintenanceInterval
      self.vmworkerPath = vmworkerPath
      self.allowedUIDs = allowedUIDs
      self.launcher = launcher
      self.actorName = actorName
      self.github = github
      self.registries = registries
      self.demandMode = demandMode
      self.shutdownDelay = shutdownDelay
      self.exitOnShutdown = exitOnShutdown
    }
  }

  public typealias ConfigParser = @Sendable (String) throws -> RunnerConfiguration

  let options: Options
  let parseConfig: ConfigParser
  let logger: Logger
  private let reconciler: Reconciler

  private var lock: DaemonLock?
  private var database: RunnerDatabase?
  private var service: DaemonServiceImpl?
  private var server: DaemonServer?
  private var supervisor: WorkerSupervisor?
  private var instances: InstanceManager?
  private var runners: RunnerSessionManager?
  private var orchestrator: Orchestrator?
  private var builder: ImageBuilder?
  /// `system shutdown --force` cancels running image builds; a plain shutdown waits them out.
  private var shutdownForce = false
  private var reconcileTask: Task<Void, Never>?
  private var maintenanceTask: Task<Void, Never>?
  /// Not `private`: `Managed/ImageUpdateLoop.swift` extends this actor from a separate file, and
  /// cross-file extensions cannot see `private` members.
  var imageUpdates: ImageUpdateService?
  var imageUpdateTask: Task<Void, Never>?
  private var metricsEndpoint: MetricsEndpoint?
  private var shutdownTask: Task<Void, Never>?
  private var hostId: HostID?
  private var eventLog: LifecycleEventLog?
  private var started = false

  /// One registry for the whole daemon (spec §43): every manager writes into it, `metrics.snapshot`
  /// and `GET /metrics` read from it.
  let metrics = MetricRegistry()

  /// One admission lock for the whole daemon: instance creation and (from Phase 5) image builds
  /// spend the same host budget, so they have to serialize against each other and not merely
  /// against their own kind (spec §121).
  let admissionQueue = AdmissionQueue()

  public init(
    options: Options,
    parseConfig: @escaping ConfigParser,
    logger: Logger = Logger(component: .daemon)
  ) {
    self.options = options
    self.parseConfig = parseConfig
    self.logger = logger
    self.reconciler = Reconciler(logger: Logger(component: .reconciler))
  }

  public var isRunning: Bool { started }

  public var socketPath: URL { options.paths.daemonSocket }

  // MARK: - Lifecycle

  public func start() async throws {
    guard !started else { throw OrchestrationError.alreadyStarted }
    do {
      try await startStages()
      started = true
    } catch {
      await teardown()
      throw error
    }
  }

  private func startStages() async throws {
    try createDirectories()
    try options.paths.validateSocketPathLengths()
    lock = try DaemonLock.acquire(at: lockURL)
    let database = try RunnerDatabase.open(at: options.paths.databaseURL)
    self.database = database
    let hostId = try HostIdentity.load(stateDir: options.paths.stateDir)
    self.hostId = hostId
    // From here on every log line this process emits carries `host_id`, without the call sites
    // having to know it (spec §117).
    LogContext.setGlobalHost(hostId)
    try await GRDBHostRepository(db: database).ensureHost(id: hostId)
    let executable = options.vmworkerPath ?? HostProbe.defaultExecutable()
    let probe = await HostProbe.run(executable: executable, logger: logger)
    let applier = ConfigApplier(
      store: GRDBConfigStore(db: database), stateDir: options.paths.stateDir)
    let pending = pendingConfiguration(applier: applier)
    let eventLog = makeEventLog(hostId: hostId, logging: pending?.logging ?? LoggingConfig())
    self.eventLog = eventLog
    let demandMode = options.demandMode ?? pending?.github.demand ?? .scaleSet
    let service = try await makeService(
      database: database, hostId: hostId, probe: probe, executable: executable, applier: applier,
      demandMode: demandMode, eventLog: eventLog)
    self.service = service
    try await service.bootstrap(configPath: options.configPath)
    await service.setShutdownHandler { [weak self] force in
      await self?.beginShutdown(force: force)
    }
    let server = DaemonServer(
      service: service, socketPath: options.paths.daemonSocket, allowedUIDs: options.allowedUIDs)
    try await server.start()
    self.server = server
    // Before the orchestrator, not on the first reconcile tick: `Orchestrator.receive` acts on a
    // demand event as soon as the provider is running, which can be well before the reconciler
    // ticks, and a session nobody is watching any more would hold the VM it was bound to out of
    // that pass (spec §69).
    if let runners { _ = await runners.recoverSessions() }
    // After the socket is up (spec §69): a slow first GitHub round trip must not delay the
    // control surface, and the first reconcile tick drives the first scheduling pass anyway.
    try await orchestrator?.start()
    try await startMetricsEndpoint(service)
    reconcileTask = startReconcileLoop()
    maintenanceTask = startMaintenanceLoop(service)
    if let imageUpdates { imageUpdateTask = startImageUpdateLoop(imageUpdates) }
    logger.info(
      "runnerd ready",
      metadata: [
        "socket": .string(options.paths.daemonSocket.path(percentEncoded: false)),
        "host_id": .string(hostId.rawValue),
        "probe": .string(probe.probeSucceeded ? "vmworker" : "fallback"),
      ])
  }

  public func stop() async {
    guard started else { return }
    started = false
    await teardown()
    logger.info("runnerd stopped")
  }

  private func teardown() async {
    await metricsEndpoint?.stop()
    metricsEndpoint = nil
    reconcileTask?.cancel()
    await reconcileTask?.value
    reconcileTask = nil
    maintenanceTask?.cancel()
    await maintenanceTask?.value
    maintenanceTask = nil
    imageUpdateTask?.cancel()
    await imageUpdateTask?.value
    imageUpdateTask = nil
    await imageUpdates?.stop()
    imageUpdates = nil
    await server?.stop()
    server = nil
    // Before the orchestrator: a build owns a VM, a worker and an image pin, and its teardown has
    // to complete while the managers it releases them through are still wired up (B4).
    await builder?.stop(cancel: shutdownForce)
    builder = nil
    // Closes the GitHub message sessions and lets in-flight creations finish (spec §108).
    await orchestrator?.stop()
    orchestrator = nil
    // Workers keep running on purpose: they own live VMs and are reconnected on the next start.
    await runners?.detachObservers()
    runners = nil
    await instances?.detachGuests()
    instances = nil
    await supervisor?.detachAll()
    supervisor = nil
    service = nil
    database = nil
    await eventLog?.close()
    eventLog = nil
    lock?.release()
    lock = nil
  }

  // MARK: - Queries

  public func status() async throws -> SystemStatus {
    guard let service else { throw OrchestrationError.notStarted }
    return try await service.status()
  }

  public func reconcileState() async -> Reconciler.Snapshot {
    await reconciler.state()
  }

  /// The daemon-wide capacity lock, exposed so Phase 5's image builder takes the *same* one the
  /// instance manager already holds during admission.
  public func hostAdmissionQueue() -> AdmissionQueue {
    admissionQueue
  }

  /// The bound Prometheus port, or `nil` when the endpoint is disabled.
  public func metricsPort() async -> UInt16? {
    await metricsEndpoint?.port()
  }

  /// Waits for a `system.shutdown` this runtime accepted. Returns immediately when none is in
  /// flight; the production daemon never reaches the end of it because `exit(0)` comes first.
  public func awaitShutdown() async {
    await shutdownTask?.value
  }

  // MARK: - Shutdown (spec §108)

  /// The service has already drained and, unless forced, waited the jobs out; all that is left is
  /// to release the socket, the lock and the database.
  private func beginShutdown(force: Bool) {
    guard shutdownTask == nil else { return }
    shutdownForce = force
    let delay = options.shutdownDelay
    let shouldExit = options.exitOnShutdown
    logger.notice("shutdown requested", metadata: ["force": .stringConvertible(force)])
    shutdownTask = Task { [weak self] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      await self?.stop()
      if shouldExit { exit(0) }
    }
  }

  /// Spec §43. A `listen` that is not loopback is a configuration error, not a warning: the
  /// endpoint names profiles, instances and host capacity.
  private func startMetricsEndpoint(_ service: DaemonServiceImpl) async throws {
    let config = await service.appliedConfiguration()?.metrics ?? MetricsConfig()
    guard config.prometheus.enabled else { return }
    let endpoint = try MetricsEndpoint(
      listen: config.prometheus.listen,
      snapshot: { await service.metricsSnapshotValue() })
    try await endpoint.start()
    metricsEndpoint = endpoint
  }

  // MARK: - Wiring

  private var lockURL: URL { options.paths.stateDir.appending(path: "runnerd.lock") }

  /// `nil` when the section is disabled, or when the file cannot be opened: the event stream is
  /// an observability nicety, not a precondition for running VMs.
  private func makeEventLog(hostId: HostID, logging: LoggingConfig) -> LifecycleEventLog? {
    guard logging.file.enabled else { return nil }
    do {
      return try LifecycleEventLog(
        url: options.paths.eventsLogFile, hostId: hostId,
        options: RotatingFileSink.Options(
          maxSizeBytes: logging.file.maxSizeBytes, maxFiles: logging.file.maxFiles))
    } catch {
      logger.warning(
        "lifecycle event stream disabled",
        metadata: ["error": .string(String(describing: error))])
      return nil
    }
  }

  private func makeService(
    database: RunnerDatabase, hostId: HostID, probe: HostProbeResult, executable: URL?,
    applier: ConfigApplier, demandMode: DemandMode, eventLog: LifecycleEventLog?
  ) async throws -> DaemonServiceImpl {
    let instanceRows = GRDBInstanceRepository(db: database)
    let imageRows = GRDBImageRepository(db: database)
    let imageStore = ImageStore(paths: options.paths)
    let instanceStore = InstanceStore(paths: options.paths, images: imageStore)
    guard let executable else {
      throw VMError.workerSpawnFailed(reason: "no vmworker executable found", cause: nil)
    }
    let supervisor = WorkerSupervisor(
      paths: options.paths, launcher: options.launcher ?? ProcessWorkerLauncher(executable: executable),
      store: instanceStore, instances: instanceRows)
    self.supervisor = supervisor
    let registryCredentials = RegistryCredentials()
    let managedRows = GRDBManagedImageRepository(db: database)
    let images = ImageManager(
      store: imageStore, images: imageRows, instances: instanceRows,
      operations: GRDBOperationRepository(db: database), managed: managedRows,
      architecture: probe.architecture,
      paths: options.paths,
      registries: options.registries
        ?? DefaultRegistryClientFactory(credentials: registryCredentials.chain()),
      metrics: metrics)
    // `.important usage` free space at the state volume, matching what admission already measures
    // (spec §17); injected as a closure so tests can drive every `DiskPressureState` directly.
    let stateDir = options.paths.stateDir
    let diskPressure = DiskPressureMonitor(freeSpace: { APFSClone.freeSpace(at: stateDir) })
    // Built before the instance manager: admission grades the image's runner version through it
    // (spec §53), so the manager needs it at construction.
    var gatewayOptions = options.github ?? GitHubGateway.Options(paths: options.paths)
    // Every GitHub HTTP attempt lands in `runnervm_github_requests_total{class}` unless a test
    // injected its own observer.
    gatewayOptions.requestObserver =
      gatewayOptions.requestObserver ?? MetricsGitHubRequestObserver(metrics: metrics)
    let gateway = GitHubGateway(options: gatewayOptions)
    let runnerVersions = RunnerVersionMonitor(gateway: gateway)
    let instances = InstanceManager(
      paths: options.paths, hostId: hostId, instances: instanceRows,
      profiles: GRDBProfileRepository(db: database), imageRows: imageRows, images: images,
      imageStore: imageStore, instanceStore: instanceStore, supervisor: supervisor, probe: probe,
      admissionQueue: admissionQueue, runnerVersions: runnerVersions)
    await instances.attachEventLog(eventLog)
    self.instances = instances
    let runners = RunnerSessionManager(
      sessions: GRDBRunnerSessionRepository(db: database), instanceRows: instanceRows,
      profiles: GRDBProfileRepository(db: database), scopes: GRDBScopeRepository(db: database),
      summaries: GRDBJobSummaryRepository(db: database),
      operations: GRDBOperationRepository(db: database), instances: instances, gateway: gateway)
    await runners.attachEventLog(eventLog)
    self.runners = runners
    await supervisor.setHandlers(
      onState: { id, state in await instances.handleWorkerState(id: id, vmState: state) },
      onDisconnect: { id in await instances.handleWorkerDisconnect(id: id) })
    let orchestrator = makeOrchestrator(
      database: database, hostId: hostId, probe: probe, instances: instances, runners: runners,
      gateway: gateway, instanceRows: instanceRows, demandMode: demandMode)
    await orchestrator.attachEventLog(eventLog)
    self.orchestrator = orchestrator
    let builder = makeBuilder(
      database: database, hostId: hostId, probe: probe, images: images, imageStore: imageStore,
      instanceRows: instanceRows, executable: executable, gateway: gateway,
      runnerVersions: runnerVersions)
    self.builder = builder
    // After the instance manager: qualification boots a maintenance VM through it, and promotion
    // retires the reusable VMs the superseded digest left behind (spec §138). After the builder:
    // a `macosTart` track is promoted by running an actual provisioning build through it (D7).
    let imageUpdates = ImageUpdateService(
      managed: managedRows, imageRows: imageRows, images: images, instances: instances,
      instanceRows: instanceRows, runnerVersions: runnerVersions,
      provisioning: MacOSProvisionLaunching(builder: builder), metrics: metrics)
    self.imageUpdates = imageUpdates
    // Both admission paths and the scheduler must charge for a running build, so the builder is
    // registered with them the moment it exists (spec §121).
    await instances.attachImageBuilds(builder)
    await orchestrator.attachImageBuilds(builder)
    await reconciler.attach(
      CompositeReconcileStep([
        InstanceReconciler(
          instances: instanceRows, manager: instances, supervisor: supervisor, store: instanceStore,
          retention: { await instances.failedInstanceRetention() }, images: images),
        // Right after the instance sweep, and before the orchestrator plans: a pinned VM whose ttl
        // has passed is capacity this pass should already see as free.
        MaintenanceInstanceReaper(
          instances: instanceRows, manager: instances, events: eventLog),
        // After the instance sweep: a VM the reconciler has just interrupted is what tells session
        // recovery the runner behind it is gone. Before the orchestrator: the sessions it closes
        // free the capacity that pass is about to plan against.
        RunnerSessionReconciler(runners: runners),
        OrchestratorReconcileStep(orchestrator: orchestrator),
        BuildReconciler(builder: builder),
      ]))
    return DaemonServiceImpl(
      paths: options.paths,
      hostId: hostId,
      database: database,
      images: images,
      instances: instances,
      supervisor: supervisor,
      applier: applier,
      reconciler: reconciler,
      parseConfig: parseConfig,
      probe: probe,
      startedAt: Date(),
      actorName: options.actorName,
      diskPressure: diskPressure,
      gateway: gateway,
      scopeHealth: ScopeHealthMonitor(
        scopes: GRDBScopeRepository(db: database), gateway: gateway),
      runnerVersions: runnerVersions,
      runners: runners,
      orchestrator: orchestrator,
      metrics: metrics,
      registryCredentials: registryCredentials,
      eventLog: eventLog,
      builder: builder,
      updates: imageUpdates,
      logger: logger)
  }

  private func startReconcileLoop() -> Task<Void, Never> {
    let reconciler = self.reconciler
    let interval = options.reconcileInterval
    let jitter = options.reconcileJitter
    return Task {
      while !Task.isCancelled {
        await reconciler.tick()
        do {
          try await Task.sleep(for: DaemonRuntime.nextDelay(interval: interval, jitter: jitter))
        } catch {
          return
        }
      }
    }
  }

  /// Disk pressure and staging cleanup (spec §17, §57) run on their own, slower cadence rather
  /// than piggybacking on `Reconciler`: they report a single maintenance action, not the
  /// instance/worker counts `ReconcileCounts` is shaped for. Ticks eagerly, like the reconcile
  /// loop, so `system.status` reports a real reading as soon as the daemon is up.
  private func startMaintenanceLoop(_ service: DaemonServiceImpl) -> Task<Void, Never> {
    let interval = options.maintenanceInterval
    return Task {
      while !Task.isCancelled {
        await service.runMaintenance()
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
      }
    }
  }

  /// Jitter keeps several hosts from reconciling in lockstep after a shared restart.
  static func nextDelay(interval: Duration, jitter: Duration) -> Duration {
    guard jitter > .zero else { return interval }
    let jitterMillis = jitter.milliseconds
    let offset = Int64.random(in: -jitterMillis...jitterMillis)
    return .milliseconds(max(1, interval.milliseconds + offset))
  }
}

extension Duration {
  var milliseconds: Int64 {
    let parts = components
    return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
  }
}
