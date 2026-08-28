import DaemonAPI
import Foundation
import GuestControl
import ImageStore
import Logging
import Metrics
import Persistence
import RPC
import RunnerCore
import RunnerLogging
import Scheduler

/// `DaemonService` backed by the repositories and the live runtime state.
///
/// YAML parsing is injected rather than imported: ConfigLoader sits above Orchestration in the
/// module graph, so `runnerd` (and the tests) supply `ConfigLoader.load(yaml:)`.
actor DaemonServiceImpl: DaemonService {
  typealias ConfigParser = @Sendable (String) throws -> RunnerConfiguration

  let paths: RunnerPaths
  let hostId: HostID
  let hosts: any HostRepository
  let scopes: any ScopeRepository
  let profiles: any ProfileRepository
  let operations: any OperationRepository
  let imageRows: any ImageRepository
  let instanceRows: any InstanceRepository
  /// Read directly (not through `builder`) for `status()`'s builds line: `builder` is `nil` in the
  /// M1-M5 test harness, and a `list(states:)` query filtered at the database is cheaper than
  /// decoding every `BuildInfoDTO` just to count two buckets.
  let imageBuildRows: any ImageBuildRepository
  let audit: any AuditRepository
  let images: ImageManager
  let instances: InstanceManager
  let supervisor: WorkerSupervisor
  let applier: ConfigApplier
  let reconciler: Reconciler
  let parseConfig: ConfigParser
  let probe: HostProbeResult
  let startedAt: Date
  let actorName: String
  let diskPressure: DiskPressureMonitor
  let gateway: GitHubGateway
  let scopeHealth: ScopeHealthMonitor
  let runnerVersions: RunnerVersionMonitor
  let runners: RunnerSessionManager
  /// `nil` in the unit-test wiring that only exercises the M1-M5 surface.
  let orchestrator: Orchestrator?
  let metrics: MetricRegistry
  let hostMode: HostModeControl
  /// Owns the registry Keychain item `registry.login` writes and the pull chain reads.
  let registryCredentials: RegistryCredentials
  /// `logs/events.jsonl`; `nil` when the file could not be opened.
  let eventLog: LifecycleEventLog?
  /// `nil` until Phase 5 wires the image builder in; the five `image.build`/`build.*` methods
  /// answer `ImageBuildError.unavailable` until then.
  let builder: (any ImageBuildService)?
  let logger: Logger

  /// Set by `DaemonRuntime` once it owns both halves. `nil` means nothing can stop the process,
  /// so `system.shutdown` reports itself unavailable rather than pretending to have worked.
  var shutdownHandler: (@Sendable (Bool) async -> Void)?

  private var appliedConfig: RunnerConfiguration?
  private var appliedYAML: String?
  private var appliedAt: Date?

  init(
    paths: RunnerPaths, hostId: HostID, database: RunnerDatabase, images: ImageManager,
    instances: InstanceManager, supervisor: WorkerSupervisor, applier: ConfigApplier,
    reconciler: Reconciler, parseConfig: @escaping ConfigParser, probe: HostProbeResult,
    startedAt: Date, actorName: String,
    diskPressure: DiskPressureMonitor = DiskPressureMonitor(freeSpace: { UInt64.max }),
    gateway: GitHubGateway, scopeHealth: ScopeHealthMonitor,
    runnerVersions: RunnerVersionMonitor, runners: RunnerSessionManager,
    orchestrator: Orchestrator? = nil, metrics: MetricRegistry = MetricRegistry(),
    registryCredentials: RegistryCredentials = RegistryCredentials(),
    eventLog: LifecycleEventLog? = nil, builder: (any ImageBuildService)? = nil, logger: Logger
  ) {
    self.paths = paths
    self.hostId = hostId
    self.hosts = GRDBHostRepository(db: database)
    self.scopes = GRDBScopeRepository(db: database)
    self.profiles = GRDBProfileRepository(db: database)
    self.operations = GRDBOperationRepository(db: database)
    self.imageRows = GRDBImageRepository(db: database)
    self.instanceRows = GRDBInstanceRepository(db: database)
    self.imageBuildRows = GRDBImageBuildRepository(db: database)
    // Every audit row is mirrored into `logs/events.jsonl` by the decorator, so the two can never
    // disagree about what an operator did.
    let auditRows = GRDBAuditRepository(db: database)
    let audit: any AuditRepository = eventLog.map {
      EventLoggingAuditRepository(base: auditRows, events: $0)
    } ?? auditRows
    self.audit = audit
    self.eventLog = eventLog
    self.builder = builder
    self.images = images
    self.instances = instances
    self.supervisor = supervisor
    self.applier = applier
    self.reconciler = reconciler
    self.parseConfig = parseConfig
    self.probe = probe
    self.startedAt = startedAt
    self.actorName = actorName
    self.diskPressure = diskPressure
    self.gateway = gateway
    self.scopeHealth = scopeHealth
    self.runnerVersions = runnerVersions
    self.runners = runners
    self.orchestrator = orchestrator
    self.metrics = metrics
    self.registryCredentials = registryCredentials
    self.hostMode = HostModeControl(
      hostId: hostId, hosts: GRDBHostRepository(db: database),
      sessions: GRDBRunnerSessionRepository(db: database),
      audit: audit, actorName: actorName,
      builds: { await DaemonServiceImpl.activeBuilds(builder) }, logger: logger)
    self.logger = logger
  }

  /// Non-terminal build rows, read through the service protocol so `HostModeControl` needs no
  /// dependency on the builder's concrete type.
  private static func activeBuilds(_ builder: (any ImageBuildService)?) async -> Int {
    guard let builder, let rows = try? await builder.list() else { return 0 }
    return rows.count { ImageBuildState(rawValue: $0.state)?.isTerminal == false }
  }

  func setShutdownHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
    shutdownHandler = handler
  }

  /// The document currently in force, for the runtime pieces that are wired once at startup.
  func appliedConfiguration() -> RunnerConfiguration? { appliedConfig }

  // MARK: - Startup

  /// Applies `configPath` when given (spec §69 step 4); otherwise adopts the document this host
  /// applied last so `config.get` and the capacity reserves survive a restart.
  func bootstrap(configPath: URL?) async throws {
    if let configPath {
      let yaml = try Self.read(configPath)
      let response = try await configApply(ConfigApplyRequest(yaml: yaml))
      logWarnings(response.issues)
      logger.info(
        "configuration applied",
        metadata: [
          "path": .string(configPath.path(percentEncoded: false)),
          "changes": .stringConvertible(response.diff.changeCount),
        ])
      return
    }
    guard let persisted = applier.loadApplied() else { return }
    appliedYAML = persisted.yaml
    appliedAt = persisted.appliedAt
    appliedConfig = try? parseConfig(persisted.yaml)
    await images.updateConfiguration(appliedConfig)
    await instances.updateConfiguration(appliedConfig)
    await gateway.updateConfiguration(appliedConfig)
    await orchestrator?.updateConfiguration(appliedConfig)
    await builder?.updateConfiguration(appliedConfig)
  }

  private static func read(_ url: URL) throws -> String {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw OrchestrationError.configUnreadable(
        path: url.path(percentEncoded: false), reason: String(describing: error))
    }
  }

  private func logWarnings(_ issues: [ConfigurationIssue]) {
    for issue in issues.warnings {
      logger.warning(
        "configuration warning",
        metadata: ["code": .string(issue.code), "path": .string(issue.path),
                   "message": .string(issue.message)])
    }
  }

  // MARK: - system.*

  func status() async throws -> SystemStatus {
    let now = Date()
    let profileRecords = try await profiles.list()
    let scopeRecords = try await scopes.list()
    let imageRecords = try await imageRows.list(state: nil)
    let instanceRecords = try await instanceRows.list(profile: nil, states: nil)
    let mode = try await hosts.mode(id: hostId)
    let pressure = await diskPressure.refresh(floorBytes: reserveDiskFloor())
    let demand = await orchestrator?.states() ?? [:]
    let scaleSetReports = await orchestrator?.demandReport() ?? []
    return SystemStatus(
      daemon: DaemonHealth(
        state: probe.probeSucceeded ? .healthy : .degraded,
        version: RunnerVMBuild.version,
        pid: getpid(),
        hostId: hostId.rawValue,
        mode: mode.rawValue,
        startedAt: RFC3339.string(from: startedAt),
        uptimeSeconds: Int64(now.timeIntervalSince(startedAt).rounded()),
        activeSessions: await hostMode.activeSessions()),
      host: Mapping.host(probe, freeDiskBytes: Mapping.freeDiskBytes(at: paths.rootDir)),
      capacity: Mapping.capacity(
        appliedConfig, runningVMs: instanceRecords.count { $0.state.hasRunningVM }),
      github: Mapping.github(
        auth: await gateway.snapshot(), scopes: scopeRecords,
        scaleSetsHealthy: scaleSetReports.count { $0.snapshot.healthy }),
      images: await imageSummary(imageRecords),
      profiles: profileRecords.map { profile in
        ProfileRuntimeSummary(
          name: profile.name, enabled: profile.enabled,
          busy: instanceRecords.count { $0.profileId == profile.id && $0.state == .busy },
          idle: instanceRecords.count { $0.profileId == profile.id && $0.state == .idle },
          demand: demand[profile.id]?.assignedJobs ?? 0,
          starting: instanceRecords.count {
            $0.profileId == profile.id && Reservation.preBootStates.contains($0.state)
          })
      },
      reconciliation: Mapping.reconciliation(await reconciler.state(), now: now),
      diskPressure: DiskPressureSummary(
        freeBytes: pressure.freeBytes, floorBytes: pressure.floorBytes,
        state: pressure.state.rawValue),
      builds: await buildsSummary())
  }

  /// Profile ids by name, for the API surfaces that take a profile name.
  func profileID(named name: String) async throws -> RunnerProfileID {
    guard let row = try await profiles.get(name: name) else {
      throw DaemonServiceError.notFound(entity: "profile", name: name)
    }
    return row.id
  }

  func reserveDiskFloor() -> UInt64 {
    (appliedConfig?.host.reserve ?? HostConfig.Reserve()).diskBytes
  }

  func version() async throws -> VersionInfo {
    VersionInfo(
      version: RunnerVMBuild.version,
      protocolName: "daemon",
      protocolVersion: 1,
      schemaVersion: RunnerVMBuild.schemaVersion)
  }

  // MARK: - config.*

  func configGet() async throws -> ConfigGetResponse {
    ConfigGetResponse(yaml: appliedYAML, appliedAt: appliedAt.map { RFC3339.string(from: $0) })
  }

  func configValidate(_ request: ConfigValidateRequest) async throws -> ConfigValidateResponse {
    let config = try parseConfig(request.yaml)
    let imageIssues = await imageIssues(config)
    return ConfigValidateResponse(issues: config.validate(host: probe.facts) + imageIssues)
  }

  func configApply(_ request: ConfigApplyRequest) async throws -> ConfigApplyResponse {
    let config = try parseConfig(request.yaml)
    // `imageIssues` needs the local image catalogue, which `RunnerConfiguration.validate` cannot
    // see, so the two sets are merged before the error gate rather than after it.
    let cached = await imageIssues(config)
    let issues = config.validate(host: probe.facts) + cached
    guard !issues.hasErrors else {
      throw ConfigurationError.validationFailed(issues: issues.errors)
    }
    let outcome = try await applier.apply(config, yaml: request.yaml, actor: actorName)
    appliedConfig = config
    appliedYAML = outcome.yaml
    appliedAt = outcome.appliedAt
    await images.updateConfiguration(config)
    await instances.updateConfiguration(config)
    await gateway.updateConfiguration(config)
    await orchestrator?.updateConfiguration(config)
    await builder?.updateConfiguration(config)
    // Spec §138: a profile whose image now resolves to a different digest retires the reusable
    // VMs still on the old one. Running instances keep their image identity either way.
    _ = await instances.retireOutdatedReusable()
    await scopeHealth.refresh()
    return ConfigApplyResponse(
      diff: outcome.diff,
      operationId: outcome.operationId.rawValue,
      issues: issues,
      appliedAt: RFC3339.string(from: outcome.appliedAt))
  }

  // MARK: - profile.* / scope.*

  func profileList() async throws -> ProfileListResponse {
    let names = try await scopeNamesById()
    let records = try await profiles.list()
    return ProfileListResponse(
      profiles: records
        .sorted { $0.name < $1.name }
        .map { Mapping.profile($0, scopeName: names[$0.scopeId] ?? $0.scopeId.rawValue) })
  }

  func profileGet(_ request: ProfileGetRequest) async throws -> ProfileSummary {
    guard let record = try await profiles.get(name: request.name) else {
      throw DaemonServiceError.notFound(entity: "profile", name: request.name)
    }
    let names = try await scopeNamesById()
    return Mapping.profile(record, scopeName: names[record.scopeId] ?? record.scopeId.rawValue)
  }

  func scopeList() async throws -> ScopeListResponse {
    let records = try await scopes.list()
    return ScopeListResponse(scopes: records.sorted { $0.name < $1.name }.map(Mapping.scope))
  }

  func scopeGet(_ request: ScopeGetRequest) async throws -> ScopeSummary {
    guard let record = try await scopes.get(name: request.name) else {
      throw DaemonServiceError.notFound(entity: "scope", name: request.name)
    }
    return Mapping.scope(record)
  }

  private func scopeNamesById() async throws -> [GitHubScopeID: String] {
    Dictionary(try await scopes.list().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: - operation.*

  func operationList() async throws -> OperationListResponse {
    let records = try await operations.list(state: nil)
    return OperationListResponse(
      operations: records.sorted { $0.startedAt > $1.startedAt }.map(Mapping.operation))
  }

  /// `OperationRepository` has no fetch-by-id, so this filters the list; v1 keeps few rows.
  func operationGet(_ request: OperationGetRequest) async throws -> OperationInfo {
    let records = try await operations.list(state: nil)
    guard let record = records.first(where: { $0.id.rawValue == request.id }) else {
      throw DaemonServiceError.notFound(entity: "operation", name: request.id)
    }
    return Mapping.operation(record)
  }

  // MARK: - image.* (delete/prune; the rest is in DaemonServiceImages.swift)

  func imageDelete(_ request: ImageDeleteRequest) async throws -> ImageDeleteResponse {
    try await images.delete(digest: ImageDigest(rawValue: request.digest))
    return ImageDeleteResponse(digest: request.digest)
  }

  func imagePrune(_ request: ImagePruneRequest) async throws -> ImagePruneResponse {
    let policy = appliedConfig?.images ?? ImageCacheConfig()
    let report = try await images.prune(policy: policy, dryRun: request.dryRun)
    return ImagePruneResponse(
      candidates: report.candidates.map(\.rawValue), deleted: report.deleted.map(\.rawValue),
      keptPinned: report.keptPinned.map(\.rawValue), reclaimedBytes: report.reclaimedBytes,
      staleStagingRemoved: report.staleStagingRemoved)
  }

  // MARK: - instance.*

  func instanceList() async throws -> InstanceListResponse {
    let names = try await profileNamesById()
    var result: [InstanceInfoDTO] = []
    for record in try await instances.list() {
      result.append(await describe(record, names: names))
    }
    return InstanceListResponse(instances: result)
  }

  func instanceGet(_ request: InstanceGetRequest) async throws -> InstanceInfoDTO {
    let record = try await instances.get(id: InstanceID(rawValue: request.id))
    return await describe(record, names: try await profileNamesById())
  }

  /// Refuses admission outright under critical disk pressure (spec §17 "stop admitting new
  /// work"), ahead of `InstanceManager.create`'s own per-request capacity check: that check only
  /// rejects a request whose own disk reservation does not fit the remaining budget, which is not
  /// the same guarantee once the *host* itself is already past its floor.
  func instanceCreate(_ request: InstanceCreateRequest) async throws -> InstanceInfoDTO {
    let options = try Self.createOptions(request, now: Date())
    let pressure = await diskPressure.refresh(floorBytes: reserveDiskFloor())
    guard pressure.state != .critical else {
      throw OrchestrationError.diskPressureCritical(
        freeBytes: pressure.freeBytes, floorBytes: pressure.floorBytes)
    }
    let record = try await instances.create(profileName: request.profile, options: options)
    return await describe(record, names: try await profileNamesById())
  }

  /// Wire request -> `InstanceCreateOptions`, with the three refusals that belong to the protocol
  /// rather than to the lifecycle: a maintenance instance must name a bounded ttl, and only a
  /// maintenance instance may run something other than its profile's image.
  ///
  /// `purpose` is parsed leniently in exactly one direction: an unknown string is an error, never
  /// a silent downgrade to `runner` — the caller asked for something this daemon does not know how
  /// to pin, and quietly handing back an ordinary VM the scheduler will cancel is worse than a
  /// refusal. Host mode is deliberately *not* special-cased: a draining host refuses a maintenance
  /// create exactly as it refuses a runner one.
  static func createOptions(
    _ request: InstanceCreateRequest, now: Date
  ) throws -> InstanceCreateOptions {
    let purpose: InstancePurpose
    if let raw = request.purpose {
      guard let parsed = InstancePurpose(rawValue: raw) else {
        throw DaemonServiceError.notFound(entity: "instance purpose", name: raw)
      }
      purpose = parsed
    } else {
      purpose = .runner
    }
    guard purpose == .maintenance else {
      guard request.imageOverride == nil else {
        throw OrchestrationError.imageOverrideMaintenanceOnly
      }
      return InstanceCreateOptions()
    }
    guard let ttlMs = request.ttlMs else { throw OrchestrationError.maintenanceTTLRequired }
    guard MaintenanceTTL.range.contains(ttlMs) else {
      throw OrchestrationError.maintenanceTTLInvalid(
        ttlMs: ttlMs, minimumMs: MaintenanceTTL.minimumMs, maximumMs: MaintenanceTTL.maximumMs)
    }
    return InstanceCreateOptions(
      purpose: .maintenance,
      pinnedUntil: now.addingTimeInterval(Double(ttlMs) / 1_000),
      imageOverride: request.imageOverride)
  }

  func instanceStop(_ request: InstanceStopRequest) async throws -> InstanceInfoDTO {
    let record = try await instances.stop(
      id: InstanceID(rawValue: request.id), force: request.force)
    return await describe(record, names: try await profileNamesById())
  }

  func instanceDelete(_ request: InstanceDeleteRequest) async throws -> InstanceInfoDTO {
    let record = try await instances.delete(id: InstanceID(rawValue: request.id))
    return await describe(record, names: try await profileNamesById())
  }

  /// Spec §126. Audited: a taint takes a VM out of service, so who asked for it and why has to
  /// survive in `audit_events`.
  func instanceTaint(_ request: InstanceTaintRequest) async throws -> InstanceInfoDTO {
    let id = InstanceID(rawValue: request.id)
    let record = try await instances.taint(id: id, reason: request.reason)
    try? await audit.record(
      kind: "vm.taint", actor: actorName, resourceType: "instance", resourceId: id.rawValue,
      detail: JSONValue.object(["reason": .string(request.reason)]).encodedString())
    return await describe(record, names: try await profileNamesById())
  }

  // MARK: - instance.* (guest)

  func instanceMetrics(_ request: InstanceMetricsRequest) async throws -> InstanceMetricsResponse {
    let id = InstanceID(rawValue: request.id)
    let guest = try await instances.metrics(id: id)
    let record = try await instances.get(id: id)
    return InstanceMetricsResponse(
      instanceId: id.rawValue, collectedAt: RFC3339.string(from: Date()), guest: guest,
      worker: record.workerPid.flatMap(HostProcessMetrics.sample))
  }

  /// Relays `agent.selfTest` the way `instanceMetrics` relays `agent.getMetrics`: the guest's own
  /// answer, verbatim, with no host-side grading of what a failed check means.
  func instanceSelfTest(_ request: InstanceSelfTestRequest) async throws -> SelfTestResult {
    try await instances.selfTest(id: InstanceID(rawValue: request.id))
  }

  /// `sshEnabled` is the profile's policy, not a probe: a profile with ssh disabled must not hand
  /// out a connection string even when the guest happens to be listening.
  func instanceSSHInfo(_ request: InstanceSSHInfoRequest) async throws -> InstanceSSHInfo {
    let id = InstanceID(rawValue: request.id)
    let record = try await instances.get(id: id)
    let info = try await instances.guestInfo(id: id)
    let enabled = try await profileConfig(record.profileId)?.ssh.enabled ?? false
    return InstanceSSHInfo(
      ipAddresses: info.ipAddresses, user: InstanceSSHInfo.defaultUser, sshEnabled: enabled)
  }

  /// Audited before the first byte leaves: `argv` goes through the central redactor, so a token
  /// passed as an argument never reaches the audit row or the log.
  func instanceExec(
    _ request: InstanceExecRequest,
    emit: @escaping @Sendable (InstanceExecChunk) async throws -> Void
  ) async throws -> InstanceExecResult {
    let id = InstanceID(rawValue: request.id)
    let redacted = request.argv.map { Redactor.standard.redact($0) }
    logger.notice(
      "vm exec invoked",
      metadata: .context(instance: id).merging([
        "argv": .array(redacted.map { .string($0) }),
        "timeout_ms": .stringConvertible(request.timeoutMs),
      ]) { $1 })
    try? await audit.record(
      kind: "vm.exec", actor: actorName, resourceType: "instance", resourceId: id.rawValue,
      detail: JSONValue.object(["argv": .array(redacted.map { .string($0) })]).encodedString())
    return try await stream(request, id: id, emit: emit)
  }

  private func stream(
    _ request: InstanceExecRequest, id: InstanceID,
    emit: @escaping @Sendable (InstanceExecChunk) async throws -> Void
  ) async throws -> InstanceExecResult {
    let events = try await instances.exec(
      id: id,
      ExecRequest(
        argv: request.argv, cwd: request.cwd, timeoutMs: request.timeoutMs,
        maxOutputBytes: request.maxOutputBytes))
    var exitCode: Int32?
    for try await event in events {
      switch event {
      case .stdout(let data): try await emit(InstanceExecChunk(stream: "stdout", data: data))
      case .stderr(let data): try await emit(InstanceExecChunk(stream: "stderr", data: data))
      case .exited(let code): exitCode = code
      }
    }
    guard let exitCode else {
      throw GuestAgentError.methodFailed(
        method: GuestMethod.exec.rawValue, reason: "the guest ended the stream without an exit code")
    }
    return InstanceExecResult(exitCode: exitCode)
  }

  private func profileConfig(_ id: RunnerProfileID) async throws -> RunnerProfileConfig? {
    guard let row = try await profiles.list().first(where: { $0.id == id }) else { return nil }
    return try row.decodedConfig()
  }

  private func describe(
    _ record: InstanceRecord, names: [RunnerProfileID: String]
  ) async -> InstanceInfoDTO {
    Mapping.instance(
      record, profileName: names[record.profileId] ?? record.profileId.rawValue,
      vmState: await supervisor.state(id: record.id)?.rawValue)
  }

  private func profileNamesById() async throws -> [RunnerProfileID: String] {
    Dictionary(
      try await profiles.list().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }
}
