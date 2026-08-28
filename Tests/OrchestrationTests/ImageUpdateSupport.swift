import Foundation
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

/// Records what D7's provisioning launcher would have been asked to do.
final class RecordingProvisionLauncher: MacOSProvisionLauncher, Sendable {
  private let calls = Mutex<[String]>([])

  func provision(_ track: ManagedImageRecord) async {
    calls.withLock { $0.append(track.name) }
  }

  var provisioned: [String] { calls.withLock { $0 } }
}
