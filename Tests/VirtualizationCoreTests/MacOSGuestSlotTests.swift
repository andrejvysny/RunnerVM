import Foundation
import RunnerCore
import Testing

@testable import VirtualizationCore

/// The two-guest ceiling is host policy, not just a scheduling decision, so it is fenced twice:
/// once in runnerd's admission (`CapacityCalculator`) and once here, in the process that actually
/// creates the `VZVirtualMachine`. This suite covers the second fence.
///
/// Every contention case runs against a *child process*, because that is the only way the fence
/// works at all: `fcntl` record locks are per-process, so two `acquire` calls inside one process
/// never conflict. vmworker is one process per VM, which is what makes that acceptable.
@Suite struct MacOSGuestSlotTests {
  private func scratch() throws -> URL { try Scratch.makeDirectory("macos-slot") }

  @Test func takesTheFirstSlotWhenNothingIsHeld() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }

    let lock = try MacOSGuestSlot.acquire(in: directory, limit: 2)

    #expect(lock.url.lastPathComponent == "macos-slot-0.lock")
  }

  @Test func skipsASlotHeldByAnotherProcess() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let holder = try SlotHolder(directory.appending(path: MacOSGuestSlot.lockName(0)))
    defer { holder.stop() }

    let lock = try MacOSGuestSlot.acquire(in: directory, limit: 2)

    #expect(lock.url.lastPathComponent == "macos-slot-1.lock")
  }

  /// A third macOS worker is refused with the error the daemon already understands, and refused
  /// before it can build a configuration or boot anything.
  @Test func refusesOnceEverySlotIsHeld() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let holders = try (0..<2).map { try SlotHolder(directory.appending(path: MacOSGuestSlot.lockName($0))) }
    defer { holders.forEach { $0.stop() } }

    let error = #expect(throws: VMError.self) {
      _ = try MacOSGuestSlot.acquire(in: directory, limit: 2)
    }

    #expect(error?.code == "VM_MACOS_GUEST_LIMIT_REACHED")
    // Retryable: "not now" rather than "never" — the slot frees when a worker exits.
    #expect(error?.retryable == true)
  }

  /// The kernel drops a record lock when the holding process dies, so a crashed worker cannot leak
  /// a slot and nothing has to reap the lock files.
  @Test func aSlotIsFreedWhenItsHolderDies() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }
    let holder = try SlotHolder(directory.appending(path: MacOSGuestSlot.lockName(0)))
    holder.stop()

    let lock = try MacOSGuestSlot.acquire(in: directory, limit: 2)

    #expect(lock.url.lastPathComponent == "macos-slot-0.lock")
  }

  @Test func theLockNamesAreStableAcrossRuns() {
    #expect(MacOSGuestSlot.lockName(0) == "macos-slot-0.lock")
    #expect(MacOSGuestSlot.lockName(1) == "macos-slot-1.lock")
  }

  /// A non-positive limit grants nothing rather than looping forever or handing out a slot.
  @Test func aLimitOfZeroGrantsNothing() throws {
    let directory = try scratch()
    defer { Scratch.remove(directory) }

    #expect(throws: VMError.self) {
      _ = try MacOSGuestSlot.acquire(in: directory, limit: 0)
    }
  }

  /// The default is the licensed ceiling, not something a caller has to remember to pass.
  @Test func theDefaultLimitIsTheHostConstant() {
    #expect(HostConstants.macOSGuestLimit == 2)
  }
}

/// Holds one slot from another process, the way a live vmworker does.
///
/// `/usr/bin/python3` ships with macOS, so this needs no fixture binary. `fcntl.lockf` is the same
/// `F_SETLK` write lock `WorkerLock` takes.
private final class SlotHolder {
  private let process = Process()

  init(_ url: URL) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      """
      import fcntl, os, sys, time
      fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
      fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      sys.stdout.write("ok\\n")
      sys.stdout.flush()
      time.sleep(300)
      """,
      url.path(percentEncoded: false),
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    // Starting the process is not the same as holding the lock; wait for it to say so.
    _ = try pipe.fileHandleForReading.read(upToCount: 3)
  }

  func stop() {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
  }
}
