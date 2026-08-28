import Foundation
import GitHubControl
import GuestControl
import ImageStore
import Logging
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// Everything an instance-lifecycle test needs: an in-memory database, a real image store on a
/// temp tree, a fake worker launcher and the two managers wired the way `DaemonRuntime` wires them.
struct M2Harness {
  let tree: TempTree
  let paths: RunnerPaths
  let database: RunnerDatabase
  let imageStore: ImageStore
  let instanceStore: InstanceStore
  let launcher: FakeWorkerLauncher
  let supervisor: WorkerSupervisor
  let images: ImageManager
  let instances: InstanceManager
  let instanceRows: any InstanceRepository
  let imageRows: any ImageRepository
  let github: FakeGitHubServer
  let registry: FakeRegistry
  let registryKeychain: InMemoryRegistryKeychain
  let registryCredentials: RegistryCredentials
  let scaleSetPlane: FakeScaleSetControlPlane
  let keychain: InMemoryKeychain
  let gateway: GitHubGateway
  let scopeHealth: ScopeHealthMonitor
  let runnerVersions: RunnerVersionMonitor
  let runners: RunnerSessionManager
  /// The lifecycle event stream every manager records into. Tests wait on transitions through
  /// `events.subscribe()` (see `awaitSession`/`awaitInstance`) instead of polling the database.
  let events: LifecycleEventLog
  /// One registry shared by every manager the harness builds, so a test can assert on what the
  /// lifecycle actually observed.
  let metrics = MetricRegistry()
  let hostId = HostID(rawValue: "test-host")

  static let linuxImageName = "test-linux"
  static let macImageName = "test-mac"
  static let imageClock = Date(timeIntervalSince1970: 1_756_000_000)

  init(
    configuration: RunnerConfiguration = M2Harness.configuration(),
    githubToken: String? = M2Harness.token,
    onDiskDatabase: Bool = false,
    registry: FakeRegistry = FakeRegistry(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) async throws {
    tree = try TempTree()
    paths = tree.paths
    for directory in [paths.stateDir, paths.imagesDir, paths.instancesDir, paths.socketDir] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    database = onDiskDatabase
      ? try RunnerDatabase.open(at: paths.databaseURL) : try RunnerDatabase.inMemory()
    _ = try await GRDBHostRepository(db: database).ensureHost(id: hostId)
    _ = try await GRDBConfigStore(db: database).apply(configuration, actor: "test")

    imageStore = ImageStore(paths: paths)
    instanceStore = InstanceStore(paths: paths, images: imageStore, allowFullCopy: true)
    instanceRows = GRDBInstanceRepository(db: database)
    imageRows = GRDBImageRepository(db: database)
    launcher = FakeWorkerLauncher(paths: paths)

    var tuning = WorkerSupervisor.Tuning()
    tuning.socketPollInterval = .milliseconds(5)
    tuning.socketPollAttempts = 400
    tuning.lockGraceAttempts = 4
    tuning.reconnectPollAttempts = 40
    // Long enough that no test observes a renewal; the lease loop is exercised manually.
    tuning.leaseInterval = .seconds(3_600)
    supervisor = WorkerSupervisor(
      paths: paths, launcher: launcher, store: launcher, instances: instanceRows, tuning: tuning)

    self.registry = registry
    registryKeychain = InMemoryRegistryKeychain()
    // Hermetic: no process environment, no `~/.docker/config.json`, only the injected keychain.
    registryCredentials = RegistryCredentials(
      keychain: registryKeychain,
      environment: EnvironmentRegistryCredentials(environment: [:]),
      dockerConfig: DockerConfigCredentials(
        configURL: tree.root.appending(path: "no-docker-config.json")))
    github = FakeGitHubServer()
    scaleSetPlane = FakeScaleSetControlPlane()
    keychain = InMemoryKeychain()
    // `source: file` in a temp state dir keeps the credential path hermetic: no process
    // environment, no login keychain, and `FilePATProvider`'s 0600 check runs for real.
    if let githubToken {
      try GitHubTokenStore.file(url: paths.stateDir.appending(path: GitHubTokenStore.fileName))
        .write(token: githubToken)
    }
    let plane = scaleSetPlane
    gateway = GitHubGateway(
      options: GitHubGateway.Options(
        paths: paths, baseURL: github.baseURL, session: github.makeSession(),
        keychain: keychain,
        http: GitHubHTTPClient.Options(retryPolicy: RetryPolicy(maxAttempts: 1)),
        scaleSetPlane: { _ in plane }))
    await gateway.updateConfiguration(configuration)
    scopeHealth = ScopeHealthMonitor(scopes: GRDBScopeRepository(db: database), gateway: gateway)
    // Frozen alongside the image clock so a test can place a release relative to `now`.
    runnerVersions = RunnerVersionMonitor(gateway: gateway, now: now)
    images = ImageManager(
      store: imageStore, images: imageRows, instances: instanceRows,
      operations: GRDBOperationRepository(db: database), architecture: "arm64", paths: paths,
      registries: FakeRegistryClientFactory(
        registry: registry, credentials: registryCredentials.chain()),
      metrics: metrics,
      // Frozen: `ImageMetadata.createdAt` is encoded into the image's content digest at second
      // resolution, so a live clock makes "importing the same bytes twice is a no-op" depend on
      // which side of a second boundary the two calls land.
      now: { M2Harness.imageClock })
    await images.updateConfiguration(configuration)
    var instanceTuning = InstanceManager.Tuning()
    instanceTuning.workerExitPollInterval = .milliseconds(5)
    instanceTuning.workerExitPollAttempts = 200
    // The readiness deadline still comes from the profile; only the poll spacing is compressed,
    // so readiness is driven by the fake agent's health script instead of by elapsed time.
    instanceTuning.agentReadiness = GuestAgentClient.ReadinessPolicy(
      initialBackoff: .milliseconds(2), maxBackoff: .milliseconds(8))
    // Drives the `reuse.maxAge` check, so a test can age a VM without waiting for one.
    instanceTuning.now = now
    instances = InstanceManager(
      paths: paths, hostId: hostId, instances: instanceRows,
      profiles: GRDBProfileRepository(db: database), imageRows: imageRows, images: images,
      imageStore: imageStore, instanceStore: instanceStore, supervisor: supervisor,
      probe: M2Harness.probe(), metrics: metrics, runnerVersions: runnerVersions,
      tuning: instanceTuning)
    let manager = instances
    await supervisor.setHandlers(
      onState: { id, state in await manager.handleWorkerState(id: id, vmState: state) },
      onDisconnect: { id in await manager.handleWorkerDisconnect(id: id) })
    await instances.updateConfiguration(configuration)

    var sessionTuning = RunnerSessionManager.Tuning()
    sessionTuning.pollInterval = .milliseconds(5)
    sessionTuning.lostPollThreshold = 2
    runners = RunnerSessionManager(
      sessions: GRDBRunnerSessionRepository(db: database), instanceRows: instanceRows,
      profiles: GRDBProfileRepository(db: database), scopes: GRDBScopeRepository(db: database),
      summaries: GRDBJobSummaryRepository(db: database),
      operations: GRDBOperationRepository(db: database), instances: instances, gateway: gateway,
      tuning: sessionTuning)
    try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
    events = try LifecycleEventLog(url: paths.eventsLogFile, hostId: hostId)
    await instances.attachEventLog(events)
    await runners.attachEventLog(events)
  }

  func cleanup() async {
    // Unblocks any `getMessage` a demand provider still has in flight before its task is
    // cancelled, so cleanup never waits on a fake long poll.
    scaleSetPlane.close()
    await runners.detachObservers()
    github.shutdown()
    registry.shutdown()
    await supervisor.detachAll()
    // detachAll only drops the daemon-side connections (mirroring production, where a detached
    // session leaves the real worker running) -- it does not stop the FakeWorker actors' RPC
    // servers, which each own a listening unix socket and a background accept thread. Stop those
    // explicitly, and before the temp tree goes away, so nothing is still touching it.
    await launcher.stopAll()
    await events.close()
    tree.remove()
  }

  // MARK: - Fixtures

  /// Reserves nothing: the tests run on whatever free space the developer's Mac happens to have.
  static func configuration(
    linuxMemory: UInt64 = ByteSize.gibibytes(2).bytes, maxInstances: Int? = nil,
    agentReady: DurationValue = .minutes(2), ssh: SSHPolicy = SSHPolicy(),
    runnerOnline: DurationValue = .minutes(2), jobMaxRuntime: DurationValue = .hours(6),
    lifecycle: InstanceLifecycle = .ephemeral, allowPublicRepositories: Bool = false,
    warmPool: WarmPoolPolicy = .disabled, concurrentVMStarts: Int = 2,
    reuse: ReusePolicy? = nil, cleanup: DurationValue = .minutes(5),
    linuxImage: String = M2Harness.linuxImageName, concurrentImagePulls: Int = 2,
    reserveDiskBytes: UInt64 = 0
  ) -> RunnerConfiguration {
    var timeouts = TimeoutPolicy.default
    timeouts.agentReady = agentReady
    timeouts.runnerOnline = runnerOnline
    timeouts.jobMaxRuntime = jobMaxRuntime
    timeouts.cleanup = cleanup
    return RunnerConfiguration(
      host: HostConfig(
        reserve: HostConfig.Reserve(cpu: 0, memoryBytes: 0, diskBytes: reserveDiskBytes),
        limits: HostConfig.Limits(
          concurrentImagePulls: concurrentImagePulls, concurrentVMStarts: concurrentVMStarts)),
      github: GitHubConfig(
        auth: GitHubAuthConfig(provider: .pat, source: .file),
        scopes: [
          GitHubScopeConfig(name: "test", kind: .repository, owner: "acme", repository: "app"),
        ]),
      profiles: [
        RunnerProfileConfig(
          name: "linux", scope: "test", image: linuxImage, guestOS: .linux,
          lifecycle: lifecycle,
          resources: ResourceSpec(
            cpuCount: 2, memoryBytes: linuxMemory, diskBytes: ByteSize.gibibytes(1).bytes),
          warmPool: warmPool, limits: ProfileLimits(maxInstances: maxInstances), ssh: ssh,
          reuse: reuse, timeouts: timeouts),
        RunnerProfileConfig(
          name: "mac", scope: "test", image: macImageName, guestOS: .macos,
          resources: ResourceSpec(
            cpuCount: 4, memoryBytes: ByteSize.gibibytes(2).bytes,
            diskBytes: ByteSize.gibibytes(1).bytes)),
      ],
      security: SecurityConfig(allowPublicRepositories: allowPublicRepositories))
  }

  static func probe() -> HostProbeResult {
    HostProbeResult(
      facts: HostFacts(
        logicalCPUCount: 12, physicalMemoryBytes: ByteSize.gibibytes(64).bytes,
        minimumAllowedCPUCount: 1, maximumAllowedCPUCount: 12,
        minimumAllowedMemoryBytes: ByteSize.mebibytes(128).bytes,
        maximumAllowedMemoryBytes: ByteSize.gibibytes(64).bytes),
      architecture: "arm64", osVersion: "15.4.0", virtualizationSupported: true,
      nestedVirtualizationSupported: false, macOSGuestLimit: 2, probeSucceeded: true)
  }

  /// A 32 MiB sparse file: large enough to be a plausible disk, free to create.
  @discardableResult
  func importLinuxImage() async throws -> ManagedImage {
    let disk = try sparseFile(named: "linux.img", bytes: 32 << 20)
    return try await images.importLocal(
      disk: disk, nvram: nil, os: .linux, name: Self.linuxImageName)
  }

  /// A macOS image only passes admission when it declares its platform *and* its sizing floors,
  /// and when its disk is exactly the profile's `resources.disk` (macOS guests can neither grow
  /// nor shrink their APFS container). The `mac` profile asks for 1 GiB; the file is sparse, so it
  /// still costs nothing.
  @discardableResult
  func importMacImage(
    minimumCPUCount: Int = 1, minimumMemoryBytes: UInt64 = ByteSize.mebibytes(512).bytes
  ) async throws -> ManagedImage {
    let bytes = ByteSize.gibibytes(1).bytes
    let disk = try sparseFile(named: "mac.img", bytes: bytes)
    let nvram = try sparseFile(named: "mac-nvram.bin", bytes: 64 << 10)
    let metadata = try macMetadataFile(
      diskBytes: bytes, minimumCPUCount: minimumCPUCount,
      minimumMemoryBytes: minimumMemoryBytes)
    return try await images.importLocal(
      disk: disk, nvram: nvram, os: .macos, name: Self.macImageName, metadataPath: metadata)
  }

  func macMetadataFile(
    named name: String = "mac-metadata.json", diskBytes: UInt64, minimumCPUCount: Int?,
    minimumMemoryBytes: UInt64?
  ) throws -> URL {
    let metadata = ImageMetadata(
      os: .macos, virtualDiskSizeBytes: diskBytes, createdAt: Self.imageClock,
      boot: ImageMetadata.Boot(type: .macos),
      macos: ImageMetadata.MacOSPlatform(
        hardwareModel: "ZmFrZS1tb2RlbA==", sourceVersion: "26.0",
        minimumCPUCount: minimumCPUCount, minimumMemoryBytes: minimumMemoryBytes))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let url = tree.root.appending(path: name)
    try encoder.encode(metadata).write(to: url)
    return url
  }

  func sparseFile(named name: String, bytes: UInt64) throws -> URL {
    let url = tree.root.appending(path: name)
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: bytes)
    try handle.close()
    return url
  }

  /// Binds a fake guest agent where vmworker would publish its bridge. Callers stop it; the
  /// socket itself goes with the temp tree.
  func startGuestAgent(
    for id: InstanceID, script: FakeGuestAgent.Script = FakeGuestAgent.Script()
  ) async throws -> FakeGuestAgent {
    let agent = FakeGuestAgent(socketPath: paths.agentSocket(id), script: script)
    try await agent.start()
    return agent
  }

  /// The service `DaemonServer` fronts, wired to the same managers the runtime would use.
  func service() -> DaemonServiceImpl {
    DaemonServiceImpl(
      paths: paths, hostId: hostId, database: database, images: images, instances: instances,
      supervisor: supervisor,
      applier: ConfigApplier(store: GRDBConfigStore(db: database), stateDir: paths.stateDir),
      reconciler: Reconciler(logger: Logger(label: "test")),
      parseConfig: { _ in throw OrchestrationError.notStarted }, probe: M2Harness.probe(),
      startedAt: Date(), actorName: "test", gateway: gateway, scopeHealth: scopeHealth,
      runnerVersions: runnerVersions, runners: runners, metrics: metrics,
      registryCredentials: registryCredentials,
      logger: Logger(label: "test"))
  }

  func record(_ id: InstanceID) async throws -> InstanceRecord {
    try #require(try await instanceRows.get(id: id))
  }

  /// Inserts a capacity-consuming row without booting anything, to simulate other tenants.
  func seedInstance(profile: String, state: InstanceState, digest: ImageDigest) async throws {
    let row = try #require(try await GRDBProfileRepository(db: database).get(name: profile))
    let config = try row.decodedConfig()
    let id = InstanceID.generate()
    try await instanceRows.insert(
      InstanceRecord(
        id: id, profileId: row.id, imageDigest: digest, hostId: hostId,
        name: "seed-\(RunnerPaths.shortID(id))", lifecycle: .ephemeral, state: state,
        desiredState: state, cpuCount: config.resources.cpuCount,
        memoryBytes: config.resources.memoryBytes, diskBytes: config.resources.diskBytes,
        diskReservationBytes: config.resources.diskBytes,
        instancePath: paths.instanceDir(id).path(percentEncoded: false), createdAt: .now))
  }
}

/// Runs `body` with a fresh `M2Harness`, guaranteeing `harness.cleanup()` -- which stops the fake
/// workers and removes the `/tmp/rvm-orch-*` temp tree -- completes before returning, whether
/// `body` throws or not.
///
/// This replaces the historical `defer { Task { await harness.cleanup() } }` pattern used
/// throughout this test target: `defer` closures cannot be `async`, so that pattern fired cleanup
/// as a new, unstructured `Task` and returned immediately without waiting for it. Nothing then
/// guaranteed that Task ran to completion before the test process moved on (or, at the end of a
/// `swift test` invocation, before the process exited), which is how this temp tree leaked by the
/// hundreds. `withHarness` awaits cleanup directly, so it is always finished before the function
/// -- and therefore the test -- returns.
func withHarness(
  configuration: RunnerConfiguration = M2Harness.configuration(),
  githubToken: String? = M2Harness.token,
  onDiskDatabase: Bool = false,
  registry: FakeRegistry = FakeRegistry(),
  now: @escaping @Sendable () -> Date = { Date() },
  _ body: (M2Harness) async throws -> Void
) async throws {
  let harness = try await M2Harness(
    configuration: configuration, githubToken: githubToken, onDiskDatabase: onDiskDatabase,
    registry: registry, now: now)
  do {
    try await body(harness)
  } catch {
    await harness.cleanup()
    throw error
  }
  await harness.cleanup()
}

/// Thrown when a wait gives up. Throwing (rather than recording an issue and returning) stops the
/// test at the wait itself instead of letting it continue with a stale record and pile up
/// follow-on failures that hide the real one.
struct WaitTimeout: Error, CustomStringConvertible {
  let description: String
}

/// Bounded poll for an observable condition that has no lifecycle event to wait on (HTTP
/// requests seen by a fake, call counts, files). Lifecycle *state* waits go through
/// `M2Harness.awaitSession`/`awaitInstance`, which are event-driven.
func waitUntil(
  _ description: String, attempts: Int = 400, interval: Duration = .milliseconds(10),
  _ condition: @Sendable () async throws -> Bool
) async throws {
  for _ in 0..<attempts {
    if try await condition() { return }
    try await Task.sleep(for: interval)
  }
  throw WaitTimeout(description: "timed out waiting for \(description)")
}

/// Hang guard around an event-driven wait. This is not a race margin: the wait itself completes
/// the instant the transition is recorded, and the bound only exists so a lifecycle that never
/// gets there fails the test instead of hanging the suite.
func withHangGuard<T: Sendable>(
  _ description: String, limit: Duration = .seconds(30),
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: limit)
      throw WaitTimeout(description: "timed out waiting for \(description)")
    }
    guard let first = try await group.next() else {
      throw WaitTimeout(description: "no result while waiting for \(description)")
    }
    group.cancelAll()
    return first
  }
}
