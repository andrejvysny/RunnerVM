import Foundation
import Persistence
import RunnerCore
import Scheduler
import Testing

@testable import Orchestration

/// Records how many `admit` bodies were ever running at once.
actor OverlapTracker {
  private var inFlight = 0
  private(set) var peak = 0
  private(set) var completed = 0

  func enter() {
    inFlight += 1
    peak = max(peak, inFlight)
  }

  func leave() {
    inFlight -= 1
    completed += 1
  }
}

/// One-shot signal, so a test can wait for a task to have *reached* a point instead of sleeping
/// long enough to assume it did.
actor Signal {
  private(set) var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fire() {
    fired = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  func wait() async {
    guard !fired else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }
}

struct StubImageBuilds: ImageBuildReservationSource {
  let reservations: [Reservation]

  func activeBuildReservations() async throws -> [Reservation] {
    reservations
  }
}

@Suite struct AdmissionQueueTests {
  @Test func admitRunsBodiesStrictlySerially() async throws {
    let queue = AdmissionQueue()
    let tracker = OverlapTracker()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask {
          try? await queue.admit {
            await tracker.enter()
            // Long enough that unserialized bodies would certainly overlap.
            try await Task.sleep(for: .milliseconds(2))
            await tracker.leave()
          }
        }
      }
    }

    #expect(await tracker.peak == 1)
    #expect(await tracker.completed == 20)
  }

  @Test func admitPropagatesTheBodysResultAndItsErrors() async throws {
    let queue = AdmissionQueue()

    #expect(try await queue.admit { 42 } == 42)
    await #expect(throws: OrchestrationError.self) {
      try await queue.admit { throw OrchestrationError.notStarted }
    }
    // The failed body still released the queue.
    #expect(try await queue.admit { "next" } == "next")
  }

  @Test func aCancelledWaiterLeavesTheQueueWithoutRunningOrBlockingOthers() async throws {
    let queue = AdmissionQueue()
    let held = Signal()
    let holder = Task {
      try await queue.admit {
        await held.fire()
        try await Task.sleep(for: .seconds(30))
      }
    }
    await held.wait()

    let cancelledRan = Signal()
    let cancelled = Task { try await queue.admit { await cancelledRan.fire() } }
    try await waitUntil("the first waiter to queue") { await queue.queueDepth == 1 }
    let survivorRan = Signal()
    let survivor = Task { try await queue.admit { await survivorRan.fire() } }
    try await waitUntil("the second waiter to queue") { await queue.queueDepth == 2 }

    cancelled.cancel()
    try await waitUntil("the cancelled waiter to leave") { await queue.queueDepth == 1 }
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    // Releasing the holder must hand the queue to the survivor, not to the abandoned ticket.
    holder.cancel()
    try await survivor.value

    #expect(await survivorRan.fired)
    #expect(await cancelledRan.fired == false)
    #expect(await queue.queueDepth == 0)
  }

  // MARK: - Instance creation

  /// Without the critical section both creates measure the host before either has inserted its
  /// row, and the 64 GiB budget admits two 40 GiB VMs (spec §121).
  @Test func concurrentCreatesAdmitOnlyWhatTheHostFits() async throws {
    try await withHarness(
      configuration: M2Harness.configuration(linuxMemory: ByteSize.gibibytes(40).bytes)
    ) { harness in
      try await harness.importLinuxImage()
      let manager = harness.instances

      let codes = await withTaskGroup(of: String?.self) { group -> [String?] in
        for _ in 0..<4 {
          group.addTask {
            do {
              _ = try await manager.create(profileName: "linux")
              return nil
            } catch {
              return (error as? any RunnerError)?.code ?? "UNKNOWN"
            }
          }
        }
        var results: [String?] = []
        for await code in group { results.append(code) }
        return results
      }

      #expect(codes.count(where: { $0 == nil }) == 1)
      #expect(codes.compactMap { $0 }.allSatisfy { $0 == "SCHEDULER_INSUFFICIENT_MEMORY" })
      let rows = try await harness.instances.list()
      #expect(rows.count == 1)
      #expect(rows.first?.state == .waitingForAgent)
      // A rejected create must not strand the temporary pin it took before admission.
      #expect(try await harness.imageRows.pins(ownerType: .planning).isEmpty)
    }
  }

  // MARK: - Build reservations

  @Test func buildReservationsJoinTheHostSnapshotAndReduceProfileCapacity() async throws {
    try await withHarness { harness in
      try await harness.importLinuxImage()
      let profiles = GRDBProfileRepository(db: harness.database)
      let stub = StubImageBuilds(reservations: [
        Reservation.imageBuild(
          id: "build-1", cpuCount: 4, memoryBytes: ByteSize.gibibytes(8).bytes,
          diskBytes: ByteSize.gibibytes(4).bytes, createdAt: Date()),
      ])

      let plain = try await InstanceAdmission.reservations(
        instances: harness.instanceRows, profiles: profiles)
      let charged = try await InstanceAdmission.reservations(
        instances: harness.instanceRows, profiles: profiles, builds: stub)

      #expect(plain.isEmpty)
      #expect(charged.map(\.profileId) == [.imageBuild])
      #expect(charged.first?.cpuCount == 4)

      // A fixed budget rather than the host's own, so the arithmetic is the same everywhere:
      // 12 vCPUs / 2 per instance = 6, minus the build's 4 vCPUs = 4.
      let budget = HostBudget(
        cpuBudget: 12, memoryBudgetBytes: ByteSize.gibibytes(64).bytes,
        freeDiskBytes: ByteSize.gibibytes(512).bytes, diskFloorBytes: 0, maxVMs: nil)
      let row = try #require(try await profiles.get(name: "linux"))
      let config = try row.decodedConfig()
      let before = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: config, reservations: plain, budget: budget, hostMode: .normal)
      let after = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: config, reservations: charged, budget: budget,
        hostMode: .normal)

      #expect(before.cap == 6)
      #expect(after.cap == 4)
    }
  }
}
