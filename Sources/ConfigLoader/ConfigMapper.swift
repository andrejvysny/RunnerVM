import RunnerCore

/// `ConfigDTO` -> `RunnerConfiguration`. Every default here either delegates to a RunnerCore
/// default initializer/static default, or applies a mapping-only policy RunnerCore has no opinion
/// on (profile `os` defaults to `.linux`, the primary v1 target — spec §18). Range/shape checking
/// (CPU too low, disk too small, ...) is deliberately left to `RunnerConfiguration.validate(host:)`
/// so this module never duplicates that logic.
enum ConfigMapper {
  static func map(_ dto: ConfigDTO) throws(ConfigLoadError) -> RunnerConfiguration {
    try RunnerConfiguration(
      version: dto.version,
      host: mapHost(dto.host),
      github: mapGitHub(dto.github),
      profiles: mapProfiles(dto.profiles ?? []),
      security: mapSecurity(dto.security),
      metrics: mapMetrics(dto.metrics),
      diagnostics: mapDiagnostics(dto.diagnostics),
      images: mapImages(dto.images),
      imageUpdates: mapImageUpdates(dto.imageUpdates),
      logging: mapLogging(dto.logging),
      build: mapBuild(dto.build)
    )
  }

  // MARK: - Host

  private static func mapHost(_ dto: ConfigDTO.Host?) -> HostConfig {
    let d = HostConfig()
    let reserve = HostConfig.Reserve(
      cpu: dto?.reserve?.cpu ?? d.reserve.cpu,
      memoryBytes: dto?.reserve?.memory?.bytes ?? d.reserve.memoryBytes,
      diskBytes: dto?.reserve?.disk?.bytes ?? d.reserve.diskBytes
    )
    let overcommit = HostConfig.Overcommit(
      cpu: dto?.overcommit?.cpu ?? d.overcommit.cpu,
      memory: dto?.overcommit?.memory ?? d.overcommit.memory,
      disk: dto?.overcommit?.disk ?? d.overcommit.disk
    )
    let limits = HostConfig.Limits(
      concurrentImagePulls: dto?.limits?.concurrentImagePulls ?? d.limits.concurrentImagePulls,
      concurrentVMStarts: dto?.limits?.concurrentVMStarts ?? d.limits.concurrentVMStarts
    )
    return HostConfig(
      reserve: reserve,
      overcommit: overcommit,
      maxVMs: dto?.maxVMs ?? d.maxVMs,
      limits: limits
    )
  }

  // MARK: - GitHub

  private static func mapGitHub(_ dto: ConfigDTO.GitHub?) throws(ConfigLoadError) -> GitHubConfig {
    let d = GitHubAuthConfig()
    let auth = GitHubAuthConfig(
      provider: dto?.auth?.provider ?? d.provider,
      source: dto?.auth?.source ?? d.source
    )
    var scopes: [GitHubScopeConfig] = []
    for (index, scope) in (dto?.scopes ?? []).enumerated() {
      try scopes.append(mapScope(scope, index: index))
    }
    return GitHubConfig(auth: auth, scopes: scopes, demand: dto?.demand ?? GitHubConfig().demand)
  }

  private static func mapScope(
    _ dto: ConfigDTO.GitHub.Scope, index: Int
  ) throws(ConfigLoadError) -> GitHubScopeConfig {
    let path = "github.scopes[\(index)]"
    guard let name = dto.name else { throw .missingKey(path: "\(path).name") }
    guard let kind = dto.type else { throw .missingKey(path: "\(path).type") }
    guard let owner = dto.owner else { throw .missingKey(path: "\(path).owner") }
    return GitHubScopeConfig(
      name: name, kind: kind, owner: owner, repository: dto.repository, runnerGroup: dto.runnerGroup
    )
  }

  // MARK: - Profiles

  private static func mapProfiles(_ dtos: [ConfigDTO.Profile]) throws(ConfigLoadError)
    -> [RunnerProfileConfig]
  {
    var profiles: [RunnerProfileConfig] = []
    for (index, dto) in dtos.enumerated() {
      try profiles.append(mapProfile(dto, index: index))
    }
    return profiles
  }

  private static func mapProfile(
    _ dto: ConfigDTO.Profile, index: Int
  ) throws(ConfigLoadError) -> RunnerProfileConfig {
    let path = "profiles[\(index)]"
    guard let name = dto.name else { throw .missingKey(path: "\(path).name") }
    guard let scope = dto.scope else { throw .missingKey(path: "\(path).scope") }
    guard let image = dto.image else { throw .missingKey(path: "\(path).image") }
    let guestOS = dto.os ?? .linux
    return RunnerProfileConfig(
      name: name,
      scope: scope,
      image: image,
      guestOS: guestOS,
      lifecycle: dto.lifecycle ?? .ephemeral,
      resources: mapResources(dto.resources, guestOS: guestOS),
      warmPool: mapWarmPool(dto.warmPool),
      limits: ProfileLimits(maxInstances: dto.limits?.maxInstances),
      ssh: SSHPolicy(enabled: dto.ssh?.enabled ?? SSHPolicy().enabled),
      reuse: mapReuse(dto.reuse),
      timeouts: mapTimeouts(dto.timeouts),
      allowHostedLabelShadowing: dto.allowHostedLabelShadowing ?? false
    )
  }

  /// `nil` when the YAML has no `resources:` block at all, so `RunnerProfileConfig.init` applies
  /// `ResourceSpec.defaults(for:)` itself instead of this module repeating that table.
  private static func mapResources(_ dto: ConfigDTO.Profile.Resources?, guestOS: GuestOS) -> ResourceSpec? {
    guard let dto else { return nil }
    let d = ResourceSpec.defaults(for: guestOS)
    return ResourceSpec(
      cpuCount: dto.cpu ?? d.cpuCount,
      memoryBytes: dto.memory?.bytes ?? d.memoryBytes,
      diskBytes: dto.disk?.bytes ?? d.diskBytes
    )
  }

  private static func mapWarmPool(_ dto: ConfigDTO.Profile.WarmPool?) -> WarmPoolPolicy {
    guard let dto else { return .disabled }
    let d = WarmPoolPolicy.disabled
    return WarmPoolPolicy(
      minIdle: dto.minIdle ?? d.minIdle,
      maxIdle: dto.maxIdle ?? d.maxIdle,
      idleTTL: dto.idleTTL ?? d.idleTTL
    )
  }

  /// `nil` unless the YAML has a `reuse:` block, matching `RunnerProfileConfig`'s own "inherit the
  /// default only when reuse is meaningful" semantics (`effectiveReuse`).
  private static func mapReuse(_ dto: ConfigDTO.Profile.Reuse?) -> ReusePolicy? {
    guard let dto else { return nil }
    let d = ReusePolicy.default
    return ReusePolicy(
      maxJobs: dto.maxJobs ?? d.maxJobs,
      maxAge: dto.maxAge ?? d.maxAge,
      recycleOnFailure: dto.recycleOnFailure ?? d.recycleOnFailure,
      maxRestarts: dto.maxRestarts ?? d.maxRestarts,
      acknowledgeSharedHost: dto.acknowledgeSharedHost ?? d.acknowledgeSharedHost
    )
  }

  /// `nil` unless the YAML has a `timeouts:` block; `RunnerProfileConfig.effectiveTimeouts`
  /// resolves that to `TimeoutPolicy.default` at the point of use.
  private static func mapTimeouts(_ dto: ConfigDTO.Profile.Timeouts?) -> TimeoutPolicy? {
    guard let dto else { return nil }
    let d = TimeoutPolicy.default
    return TimeoutPolicy(
      imagePull: dto.imagePull ?? d.imagePull,
      clone: dto.clone ?? d.clone,
      vmBoot: dto.vmBoot ?? d.vmBoot,
      agentReady: dto.agentReady ?? d.agentReady,
      jitGeneration: dto.jitGeneration ?? d.jitGeneration,
      runnerOnline: dto.runnerOnline ?? d.runnerOnline,
      jobMaxRuntime: dto.jobMaxRuntime ?? d.jobMaxRuntime,
      gracefulShutdown: dto.gracefulShutdown ?? d.gracefulShutdown,
      cleanup: dto.cleanup ?? d.cleanup
    )
  }

  // MARK: - Remaining sections

  private static func mapSecurity(_ dto: ConfigDTO.Security?) -> SecurityConfig {
    SecurityConfig(allowPublicRepositories: dto?.allowPublicRepositories ?? SecurityConfig()
      .allowPublicRepositories)
  }

  private static func mapMetrics(_ dto: ConfigDTO.Metrics?) -> MetricsConfig {
    let d = MetricsConfig.Prometheus()
    let prometheus = MetricsConfig.Prometheus(
      enabled: dto?.prometheus?.enabled ?? d.enabled,
      listen: dto?.prometheus?.listen ?? d.listen
    )
    return MetricsConfig(prometheus: prometheus)
  }

  private static func mapDiagnostics(_ dto: ConfigDTO.Diagnostics?) -> DiagnosticsConfig {
    DiagnosticsConfig(
      failedInstanceRetention: dto?.failedInstanceRetention ?? DiagnosticsConfig().failedInstanceRetention
    )
  }

  private static func mapImages(_ dto: ConfigDTO.Images?) -> ImageCacheConfig {
    let d = ImageCacheConfig()
    let dl = ImageLimitsConfig()
    let limits = ImageLimitsConfig(
      maxVirtualDiskBytes: dto?.limits?.maxVirtualDiskSize?.bytes ?? dl.maxVirtualDiskBytes,
      maxLayers: dto?.limits?.maxLayers ?? dl.maxLayers
    )
    return ImageCacheConfig(
      maxSizeBytes: dto?.cache?.maxSize?.bytes ?? d.maxSizeBytes,
      keepRecentlyUsed: dto?.cache?.keepRecentlyUsed ?? d.keepRecentlyUsed,
      limits: limits
    )
  }

  private static func mapBuild(_ dto: ConfigDTO.Build?) -> ImageBuildConfig {
    let d = ImageBuildConfig()
    return ImageBuildConfig(
      cpuCount: dto?.cpu ?? d.cpuCount,
      memoryBytes: dto?.memory?.bytes ?? d.memoryBytes,
      diskBytes: dto?.disk?.bytes ?? d.diskBytes,
      timeout: dto?.timeout ?? d.timeout,
      stepTimeout: dto?.stepTimeout ?? d.stepTimeout,
      maxConcurrent: dto?.maxConcurrent ?? d.maxConcurrent,
      cacheDir: dto?.cacheDir ?? d.cacheDir,
      guestAgentPath: dto?.guestAgentPath ?? d.guestAgentPath,
      recipeFileName: dto?.recipeFileName ?? d.recipeFileName,
      maxContextBytes: dto?.maxContextSize?.bytes ?? d.maxContextBytes,
      maxLogBytes: dto?.maxLogSize?.bytes ?? d.maxLogBytes,
      maxSteps: dto?.maxSteps ?? d.maxSteps,
      cache: mapBaseImageCache(dto?.cache)
    )
  }

  private static func mapBaseImageCache(_ dto: ConfigDTO.Build.Cache?) -> BaseImageCachePolicy {
    let d = BaseImageCachePolicy()
    return BaseImageCachePolicy(
      maxBytes: dto?.maxBytes?.bytes ?? d.maxBytes,
      minimumHostFreeBytes: dto?.minimumHostFreeBytes?.bytes ?? d.minimumHostFreeBytes,
      maxEntries: dto?.maxEntries ?? d.maxEntries
    )
  }

  private static func mapLogging(_ dto: ConfigDTO.Logging?) -> LoggingConfig {
    let d = LoggingConfig()
    let file = LoggingConfig.FileConfig(
      enabled: dto?.file?.enabled ?? d.file.enabled,
      maxSizeBytes: dto?.file?.maxSize?.bytes ?? d.file.maxSizeBytes,
      maxFiles: dto?.file?.maxFiles ?? d.file.maxFiles
    )
    let retention = LoggingConfig.RetentionConfig(
      instanceLogs: dto?.retention?.instanceLogs ?? d.retention.instanceLogs
    )
    return LoggingConfig(
      file: file,
      retention: retention,
      collectRunnerDiagnostics: dto?.collectRunnerDiagnostics ?? d.collectRunnerDiagnostics,
      diagnosticsTimeout: dto?.diagnosticsTimeout ?? d.diagnosticsTimeout
    )
  }

  private static func mapImageUpdates(_ dto: ConfigDTO.ImageUpdates?) -> ImageUpdatesConfig {
    ImageUpdatesConfig(
      recycleReusable: dto?.recycleReusable ?? ImageUpdatesConfig().recycleReusable,
      denyTooOldRunner: dto?.denyTooOldRunner ?? ImageUpdatesConfig().denyTooOldRunner
    )
  }
}
