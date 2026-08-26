import DaemonAPI
import Foundation
import Logging
import Persistence
import Synchronization
import Testing

@testable import Orchestration

@Suite struct DiskPressureMonitorTests {
  @Test func classifyReturnsOkWellAboveTheFloor() {
    let state = DiskPressureMonitor.classify(freeBytes: 100 << 30, floorBytes: 10 << 30)
    #expect(state == .ok)
  }

  @Test func classifyReturnsWarningInsideTheTenPercentCushion() {
    // Floor 10GiB, cushion ceiling 11GiB: 10.5GiB free is inside the cushion.
    let floor: UInt64 = 10 << 30
    let state = DiskPressureMonitor.classify(freeBytes: floor + floor / 20, floorBytes: floor)
    #expect(state == .warning)
  }

  @Test func classifyReturnsCriticalAtOrBelowTheFloor() {
    #expect(DiskPressureMonitor.classify(freeBytes: 10 << 30, floorBytes: 10 << 30) == .critical)
    #expect(DiskPressureMonitor.classify(freeBytes: 1, floorBytes: 10 << 30) == .critical)
  }

  @Test func refreshReflectsAnInjectedFreeSpaceFunctionAsItChanges() async {
    let free = Mutex<UInt64>(100 << 30)
    let monitor = DiskPressureMonitor(freeSpace: { free.withLock { $0 } })

    var report = await monitor.refresh(floorBytes: 10 << 30)
    #expect(report.state == .ok)

    free.withLock { $0 = 10 << 30 }
    report = await monitor.refresh(floorBytes: 10 << 30)
    #expect(report.state == .critical)
    #expect(report.freeBytes == 10 << 30)

    free.withLock { $0 = 100 << 30 }
    report = await monitor.refresh(floorBytes: 10 << 30)
    #expect(report.state == .ok)
  }

  // MARK: - instance.create admission

  @Test func instanceCreateIsRefusedUnderCriticalDiskPressure() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let service = harness.service(diskPressure: DiskPressureMonitor(freeSpace: { 0 }))

      let error = await #expect(throws: OrchestrationError.self) {
        _ = try await service.instanceCreate(InstanceCreateRequest(profile: "linux"))
      }
      #expect(error?.code == "DISK_PRESSURE")
      #expect(try await harness.instances.list().isEmpty)
    }
  }

  @Test func instanceCreateSucceedsWhenDiskPressureIsOk() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let service = harness.service(diskPressure: DiskPressureMonitor(freeSpace: { UInt64.max }))

      let created = try await service.instanceCreate(InstanceCreateRequest(profile: "linux"))

      #expect(created.profile == "linux")
      #expect(try await harness.instances.list().count == 1)
    }
  }

  @Test func statusReportsDiskPressure() async throws {
    try await withHarness { harness in
      let service = harness.service(diskPressure: DiskPressureMonitor(freeSpace: { 0 }))
      let status = try await service.status()
      #expect(status.diskPressure.state == "critical")
      #expect(status.diskPressure.freeBytes == 0)
    }
  }
}

extension M2Harness {
  /// Same wiring as `service()`, but with a caller-supplied `DiskPressureMonitor` so a test can
  /// drive every `DiskPressureState` without depending on the real host's free space.
  func service(diskPressure: DiskPressureMonitor) -> DaemonServiceImpl {
    DaemonServiceImpl(
      paths: paths, hostId: hostId, database: database, images: images, instances: instances,
      supervisor: supervisor,
      applier: ConfigApplier(store: GRDBConfigStore(db: database), stateDir: paths.stateDir),
      reconciler: Reconciler(logger: Logger(label: "test")),
      parseConfig: { _ in throw OrchestrationError.notStarted }, probe: M2Harness.probe(),
      startedAt: Date(), actorName: "test", diskPressure: diskPressure, gateway: gateway,
      scopeHealth: scopeHealth, runners: runners, logger: Logger(label: "test"))
  }
}
