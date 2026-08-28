import DaemonAPI
import Foundation
import Metrics
import Persistence
import RunnerCore

/// `image.*` reads and the runner-software freshness they carry (spec §53). Split out of
/// `DaemonServiceImpl.swift` to keep that file under its line budget; every member below runs
/// actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  func imageList() async throws -> ImageListResponse {
    var result: [ImageInfoDTO] = []
    for managed in try await images.list() { result.append(await describe(managed)) }
    return ImageListResponse(images: result)
  }

  func imageGet(_ request: ImageGetRequest) async throws -> ImageInfoDTO {
    await describe(try await images.get(reference: request.ref))
  }

  private func describe(_ managed: ManagedImage) async -> ImageInfoDTO {
    let version = managed.record.runnerVersion
    return Mapping.image(
      managed,
      runnerVersionHealth: await runnerVersions.health(forVersion: version),
      firstMissed: await runnerVersions.firstMissedRelease(forVersion: version))
  }

  func imageImport(_ request: ImageImportRequest) async throws -> ImageInfoDTO {
    guard let os = GuestOS(rawValue: request.os) else {
      throw ImageError.metadataInvalid(reason: "unknown guest os '\(request.os)'")
    }
    let imported = try await images.importLocal(
      disk: URL(fileURLWithPath: request.path),
      nvram: request.nvramPath.map { URL(fileURLWithPath: $0) },
      os: os, name: request.name, hardwareModel: request.hardwareModel,
      metadataPath: request.metadataPath.map { URL(fileURLWithPath: $0) },
      guestAgent: request.guestAgent ?? true)
    return await describe(imported)
  }

  /// Spec §58. A profile that names an image this host already has, and that image declares no
  /// RunnerVM guest agent, is a configuration that can never start a VM -- so `config validate`
  /// reports it and `config apply` refuses, rather than letting the first `vm create` discover it.
  ///
  /// Only images actually in the store are graded. "Not pulled yet" is not a configuration error:
  /// resolving a remote reference here would turn `config validate` into a network call, and the
  /// pull path already refuses an agentless image before it transfers anything.
  func imageIssues(_ config: RunnerConfiguration) async -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    for (index, profile) in config.profiles.enumerated() {
      guard let managed = try? await images.get(reference: profile.image),
            let metadata = managed.metadata, !metadata.hasGuestAgent
      else { continue }
      issues.append(
        .error(
          "PROFILE_IMAGE_NO_GUEST_AGENT", "profiles[\(index)].image",
          "image '\(profile.image)' declares no RunnerVM guest agent, so this profile can never "
            + "run a job; build one with `runnerctl image build` or point the profile at an image "
            + "that carries the agent"))
    }
    return issues
  }

  /// Spec §53. Republished as a whole label set on every maintenance pass, like the other gauges,
  /// so a deleted image's series disappears instead of freezing at its last bucket.
  func refreshRunnerVersionMetrics() async {
    let records = (try? await imageRows.list(state: nil)) ?? []
    var gauges: [([String: String], Double)] = []
    for record in records {
      let health = await runnerVersions.health(forVersion: record.runnerVersion)
      gauges.append((
        [
          RunnerVMMetrics.digestLabel: record.digest.rawValue,
          RunnerVMMetrics.healthLabel: health.rawValue,
        ], 1))
    }
    await metrics.replaceGauge(RunnerVMMetrics.imageRunnerVersionHealth, with: gauges)
    let age = await runnerVersions.releaseAgeSeconds()
    await metrics.replaceGauge(
      RunnerVMMetrics.runnerLatestReleaseAgeSeconds, with: age.map { [([:], $0)] } ?? [])
  }

  /// `cached`/`pulling` come from the row state; the freshness counts are graded live against the
  /// last known release, so a `status` taken before the first GitHub lookup reports zero of each
  /// rather than a stale verdict.
  func imageSummary(_ records: [ImageRecord]) async -> ImageSummary {
    var stale = 0
    var tooOld = 0
    for record in records where record.state == .ready {
      switch await runnerVersions.health(forVersion: record.runnerVersion) {
      case .stale: stale += 1
      case .tooOld: tooOld += 1
      case .healthy, .unknown: break
      }
    }
    return ImageSummary(
      cached: records.count { $0.state == .ready },
      diskUsageBytes: records.reduce(0) { $0 + ($1.allocatedSizeBytes ?? $1.virtualSizeBytes) },
      pulling: records.count { $0.state == .pulling },
      runnerStale: stale, runnerTooOld: tooOld)
  }
}
