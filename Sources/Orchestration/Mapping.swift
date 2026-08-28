import DaemonAPI
import Foundation
import Persistence
import RunnerCore

/// Persistence records -> daemon API DTOs. Kept in one place so the wire shape does not drift
/// between `profile.list` and `profile.get`.
enum Mapping {
  static func profile(_ record: RunnerProfileRecord, scopeName: String) -> ProfileSummary {
    ProfileSummary(
      name: record.name,
      scope: scopeName,
      image: record.imageReference,
      guestOS: record.guestOS.rawValue,
      lifecycle: record.lifecycle.rawValue,
      cpuCount: record.cpuCount,
      memoryBytes: record.memoryBytes,
      diskBytes: record.diskBytes,
      minIdle: record.minIdle,
      maxIdle: record.maxIdle,
      maxInstances: record.maxInstances,
      sshEnabled: record.sshEnabled,
      enabled: record.enabled,
      updatedAt: RFC3339.string(from: record.updatedAt.date))
  }

  static func scope(_ record: GitHubScopeRecord) -> ScopeSummary {
    ScopeSummary(
      name: record.name,
      kind: record.kind.rawValue,
      owner: record.owner,
      repository: record.repository,
      runnerGroup: record.runnerGroupName,
      enabled: record.enabled,
      health: record.health,
      updatedAt: RFC3339.string(from: record.updatedAt.date))
  }

  static func operation(_ record: OperationRecord) -> OperationInfo {
    OperationInfo(
      id: record.id.rawValue,
      kind: record.kind,
      resourceType: record.resourceType,
      resourceId: record.resourceId,
      state: record.state.rawValue,
      startedAt: RFC3339.string(from: record.startedAt.date),
      finishedAt: record.finishedAt.map { RFC3339.string(from: $0.date) },
      errorCode: record.errorCode,
      errorMessage: record.errorMessage,
      result: operationResult(record.metadataJson))
  }

  /// Only a flat string map is a "result"; anything else in `metadata_json` stays internal.
  static func operationResult(_ json: String?) -> [String: String]? {
    guard let json, let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data),
          !decoded.isEmpty
    else { return nil }
    return decoded
  }

  static func host(_ probe: HostProbeResult, freeDiskBytes: UInt64) -> HostSummary {
    HostSummary(
      osVersion: probe.osVersion,
      architecture: probe.architecture,
      logicalCPUCount: probe.facts.logicalCPUCount,
      physicalMemoryBytes: probe.facts.physicalMemoryBytes,
      freeDiskBytes: freeDiskBytes,
      virtualizationSupported: probe.virtualizationSupported,
      nestedVirtualizationSupported: probe.nestedVirtualizationSupported,
      macOSGuestLimit: probe.macOSGuestLimit,
      probeSucceeded: probe.probeSucceeded,
      probeError: probe.failureReason)
  }

  static func capacity(_ config: RunnerConfiguration?, runningVMs: Int) -> CapacitySummary {
    let reserve = config?.host.reserve ?? HostConfig.Reserve()
    var maxVMs: Int?
    if case .count(let limit) = config?.host.maxVMs { maxVMs = limit }
    return CapacitySummary(
      runningVMs: runningVMs,
      maxVMs: maxVMs,
      reservedCPUCount: reserve.cpu,
      reservedMemoryBytes: reserve.memoryBytes,
      reservedDiskBytes: reserve.diskBytes,
      placeholder: false,
      diskOvercommit: config?.host.overcommit.disk ?? HostConfig.Overcommit().disk)
  }

  /// Auth and scopes come from local state — the cached auth probe and the persisted scope health
  /// — so `system.status` answers even while GitHub is unreachable. `scaleSetsHealthy` is the
  /// caller's count over the same `demandReport()` rows `scaleset.list` renders, rather than a
  /// second opinion: it was hardcoded to 0, so `status` reported "Scale sets: 0 healthy" on a host
  /// whose only scale set was `ready`/`open`/`ok` in `scaleset list` — an operator reading status
  /// during a deployment sees a broken GitHub connection that is not broken.
  static func github(
    auth: AuthStatus, scopes: [GitHubScopeRecord], scaleSetsHealthy: Int
  ) -> GitHubSummary {
    let enabled = scopes.filter(\.enabled)
    return GitHubSummary(
      authState: auth.state,
      authLogin: auth.login,
      scopeCount: enabled.count,
      scopesHealthy: enabled.count { $0.health == GitHubMapping.healthy },
      scaleSetsHealthy: scaleSetsHealthy,
      placeholder: false)
  }

  static func image(
    _ managed: ManagedImage, runnerVersionHealth: RunnerVersionHealth = .unknown,
    firstMissed: RunnerRelease? = nil
  ) -> ImageInfoDTO {
    ImageInfoDTO(
      digest: managed.record.digest.rawValue,
      name: managed.name,
      os: managed.record.os.rawValue,
      architecture: managed.record.architecture,
      state: managed.record.state.rawValue,
      virtualSizeBytes: managed.record.virtualSizeBytes,
      allocatedSizeBytes: managed.allocatedBytes,
      localPath: managed.record.localPath,
      pinCount: managed.pinCount,
      createdAt: RFC3339.string(from: managed.record.createdAt.date),
      canonicalReference: managed.record.canonicalReference,
      pulledAt: managed.record.pulledAt.map { RFC3339.string(from: $0.date) },
      runnerVersion: managed.record.runnerVersion,
      runnerVersionHealth: runnerVersionHealth,
      runnerFirstMissedVersion: firstMissed?.version,
      runnerFirstMissedPublishedAt: firstMissed.map { RFC3339.string(from: $0.publishedAt) },
      provenance: managed.metadata?.provenance.map(provenance),
      // Absent provenance means the image was built or pulled in RunnerVM's own format: only an
      // import records where else it could have come from (spec §58).
      sourceFormat: managed.metadata?.provenance?.imported?.format ?? "runnervm",
      guestAgent: managed.metadata?.hasGuestAgent)
  }

  /// Summary only: `packages` is the whole `dpkg` manifest and stays in `metadata.json`, where a
  /// rebuild diff can read it, instead of crossing the socket on every `image list`.
  static func provenance(_ source: ImageMetadata.Provenance) -> ImageProvenanceSummaryDTO {
    ImageProvenanceSummaryDTO(
      baseImageSource: source.baseImage?.source,
      baseImageSHA256: source.baseImage?.sha256,
      runnerSHA256: source.actionsRunner?.sha256,
      guestAgentCommit: source.guestAgent?.gitCommit,
      dockerVersion: source.docker?.version,
      kernelVersion: source.kernelVersion,
      packageUpgrade: source.packageUpgrade,
      packageCount: source.packages?.count,
      diskSHA256: source.diskSHA256,
      builtAt: source.builder?.builtAt,
      builderCommit: source.builder?.gitCommit,
      importedFormat: source.imported?.format,
      importedManifestDigest: source.imported?.manifestDigest)
  }

  static func instance(
    _ record: InstanceRecord, profileName: String, vmState: String?
  ) -> InstanceInfoDTO {
    InstanceInfoDTO(
      id: record.id.rawValue,
      name: record.name,
      profile: profileName,
      imageDigest: record.imageDigest.rawValue,
      state: record.state.rawValue,
      lifecycle: record.lifecycle.rawValue,
      vmState: vmState,
      workerPid: record.workerPid,
      workerGeneration: record.workerGeneration,
      cpuCount: record.cpuCount,
      memoryBytes: record.memoryBytes,
      diskBytes: record.diskBytes,
      diskReservationBytes: record.diskReservationBytes,
      createdAt: RFC3339.string(from: record.createdAt.date),
      startedAt: record.startedAt.map { RFC3339.string(from: $0.date) },
      agentReadyAt: record.agentReadyAt.map { RFC3339.string(from: $0.date) },
      stoppedAt: record.stoppedAt.map { RFC3339.string(from: $0.date) },
      bootId: record.bootId,
      tainted: record.tainted,
      taintReason: record.taintReason,
      jobsConsumed: record.jobsConsumed,
      retireAfterSession: record.retireAfterSession,
      failureCode: record.failureCode,
      failureMessage: record.failureMessage)
  }

  static func reconciliation(_ snapshot: Reconciler.Snapshot, now: Date) -> ReconciliationSummary {
    ReconciliationSummary(
      lastRunAt: snapshot.lastRunAt.map { RFC3339.string(from: $0) },
      secondsSinceLastRun: snapshot.lastRunAt.map { Int64(now.timeIntervalSince($0).rounded()) },
      runCount: snapshot.runCount,
      errorCount: snapshot.errorCount,
      lastError: snapshot.lastError,
      instanceCount: snapshot.counts.instances,
      workerCount: snapshot.counts.workersConnected,
      orphanCount: snapshot.counts.orphans)
  }

  /// `.systemFreeSize` on the volume backing the RunnerVM root; 0 when the path is unreadable.
  static func freeDiskBytes(at url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfFileSystem(
      forPath: url.path(percentEncoded: false))
    return (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
  }
}
