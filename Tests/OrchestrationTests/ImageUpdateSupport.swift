import Foundation
import ImageStore
import Logging
import OCIRegistry
import Persistence
import RunnerCore
import Synchronization
import Testing

@testable import Orchestration

extension M2Harness {
  var managedRows: any ManagedImageRepository { GRDBManagedImageRepository(db: database) }

  /// The update service wired the way `DaemonRuntime` wires it, with the sleeps compressed so a
  /// qualification gate is driven by the fake agent rather than by elapsed time.
  func imageUpdates(
    configuration: RunnerConfiguration,
    provisioning: (any MacOSProvisionLauncher)? = nil
  ) async -> ImageUpdateService {
    var tuning = ImageUpdateService.Tuning()
    tuning.firstCycleDelay = .milliseconds(1)
    tuning.smokeTestPollInterval = .milliseconds(10)
    tuning.smokeTestTimeout = .seconds(20)
    let service = ImageUpdateService(
      managed: managedRows, imageRows: imageRows, images: images, instances: instances,
      instanceRows: instanceRows, runnerVersions: runnerVersions, provisioning: provisioning,
      metrics: metrics, tuning: tuning, logger: Logger(label: "test"))
    await service.updateConfiguration(configuration)
    return service
  }

  func managedTrack(_ name: String) async throws -> ManagedImageRecord {
    try #require(try await managedRows.get(name: name))
  }

  /// The `linux` profile pointed at `image`, with `images.updates` spelled out.
  static func updateConfiguration(
    image: String,
    enabled: Bool = true,
    smokeTest: Bool = false,
    keepPrevious: Int = 1,
    lifecycle: InstanceLifecycle = .ephemeral,
    managed: [ManagedImageSourceConfig] = []
  ) -> RunnerConfiguration {
    var config = M2Harness.configuration(lifecycle: lifecycle, linuxImage: image)
    config.images.updates = ImageUpdatePolicyConfig(
      enabled: enabled, keepPrevious: keepPrevious, smokeTest: smokeTest)
    config.images.managed = managed
    return config
  }

  /// Every HTTP request the fake registry has seen since the last `resetRecording`.
  var registryRequestCount: Int { registry.recorded.count }
}

/// Stands in for the provisioning builder: records what it was asked to provision and answers
/// with a digest the test has already put in the store (or throws).
final class RecordingProvisionLauncher: MacOSProvisionLauncher, Sendable {
  struct Call: Sendable, Equatable {
    var name: String
    var sourceDigest: String
  }

  private let calls = Mutex<[Call]>([])
  private let outcome: Result<ImageDigest, ProvisionLauncherError>

  init(result: ImageDigest) {
    outcome = .success(result)
  }

  init(failure: String) {
    outcome = .failure(ProvisionLauncherError(reason: failure))
  }

  func provision(_ track: ManagedImageRecord, sourceDigest: String) async throws -> ImageDigest {
    calls.withLock { $0.append(Call(name: track.name, sourceDigest: sourceDigest)) }
    return try outcome.get()
  }

  var recorded: [Call] { calls.withLock { $0 } }
  var provisioned: [String] { recorded.map(\.name) }
}

struct ProvisionLauncherError: Error, CustomStringConvertible {
  let reason: String
  var description: String { reason }
}
