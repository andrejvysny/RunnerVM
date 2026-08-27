import Foundation
import ImageStore
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Composition-root wiring split out of `DaemonRuntime.swift` to keep that file under its line
/// budget: the directory layout, the demand-provider choice, the pre-bootstrap configuration peek,
/// and the image builder. Every member runs actor-isolated on `DaemonRuntime`.
extension DaemonRuntime {
  /// Spec §13: the rest of the daemon only ever sees `any DemandProvider`.
  func makeOrchestrator(
    database: RunnerDatabase, hostId: HostID, probe: HostProbeResult, instances: InstanceManager,
    runners: RunnerSessionManager, gateway: GitHubGateway, instanceRows: any InstanceRepository,
    demandMode: DemandMode
  ) -> Orchestrator {
    let scaleSets = GRDBScaleSetRepository(db: database)
    let demand: any DemandProvider = switch demandMode {
    case .manual:
      ManualDemandProvider()
    case .scaleSet:
      ScaleSetDemandProvider(
        owner: hostId.rawValue, profiles: GRDBProfileRepository(db: database),
        scopes: GRDBScopeRepository(db: database), scaleSets: scaleSets,
        plane: { await gateway.scaleSetControlPlane() })
    }
    logger.info("demand provider", metadata: ["mode": .string(demandMode.rawValue)])
    return Orchestrator(
      hostId: hostId, paths: options.paths, probe: probe,
      hosts: GRDBHostRepository(db: database), profiles: GRDBProfileRepository(db: database),
      instanceRows: instanceRows, sessionRows: GRDBRunnerSessionRepository(db: database),
      scaleSets: scaleSets, instances: instances, runners: runners, demand: demand,
      metrics: metrics)
  }

  /// The in-daemon image builder (spec §59-§62). Shares the daemon's one `AdmissionQueue`, so a
  /// build and a `vm create` contend for the same host budget rather than each measuring a stale
  /// snapshot of it (B3).
  func makeBuilder(
    database: RunnerDatabase, hostId: HostID, probe: HostProbeResult, images: ImageManager,
    imageStore: ImageStore, instanceRows: any InstanceRepository, executable: URL,
    gateway: GitHubGateway, runnerVersions: RunnerVersionMonitor
  ) -> ImageBuilder {
    ImageBuilder(
      paths: options.paths, hostId: hostId, builds: GRDBImageBuildRepository(db: database),
      imageRows: GRDBImageRepository(db: database),
      operations: GRDBOperationRepository(db: database), images: images, imageStore: imageStore,
      buildStore: BuildStore(paths: options.paths, images: imageStore),
      launcher: options.launcher ?? ProcessWorkerLauncher(executable: executable), probe: probe,
      instances: instanceRows, profiles: GRDBProfileRepository(db: database),
      hosts: GRDBHostRepository(db: database), admissionQueue: admissionQueue,
      runnerVersions: runnerVersions, gateway: gateway, metrics: metrics,
      logger: Logger(component: .image))
  }

  /// The demand provider and the log files are wired once, before `service.bootstrap` has parsed
  /// and applied a configuration (spec §69 step 4 runs after the API surface is up), so this peeks
  /// at whatever `bootstrap` is about to apply -- `--config` if given, else the last persisted
  /// document. A parse failure here is silently ignored and every caller falls back to its
  /// default; `bootstrap` re-parses for real right after and surfaces the error properly.
  func pendingConfiguration(applier: ConfigApplier) -> RunnerConfiguration? {
    let yaml: String? = if let configPath = options.configPath {
      try? String(contentsOf: configPath, encoding: .utf8)
    } else {
      applier.loadApplied()?.yaml
    }
    guard let yaml else { return nil }
    return try? parseConfig(yaml)
  }

  func createDirectories() throws {
    let manager = FileManager.default
    for directory in [options.paths.stateDir, options.paths.imagesDir, options.paths.instancesDir,
                      options.paths.daemonLogsDir, options.paths.instanceLogsDir,
                      options.paths.buildsDir, options.paths.buildLogsDir,
                      options.paths.baseImageCacheDir] {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    // 0700: the socket directory is the daemon's control surface, not a shared temp dir. Build
    // workers get their own namespace inside it so a build and an instance sharing a short-id
    // prefix cannot collide (B8).
    for directory in [options.paths.socketDir, options.paths.buildSocketDir] {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try manager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
    }
  }
}
