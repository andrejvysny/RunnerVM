import Foundation
import RunnerCore
import Testing
import VirtualizationCore
import WorkerProtocol

@testable import vmworker

/// `vmworker run` option parsing. `--graceful-ms` is what runnerd uses to hand a worker the
/// instance profile's `timeouts.gracefulShutdown` for the shutdowns the worker starts by itself.
@Suite struct RunOptionsTests {
  private static let required = [
    "--instance", "8f0f6b0e-0000-4000-8000-000000000000", "--spec", "/tmp/spec.json",
    "--socket-dir", "/tmp", "--generation", "3", "--nonce", "deadbeef",
  ]

  @Test func gracefulMsDefaultsToThirtySeconds() throws {
    #expect(try Run.parse(Self.required).gracefulMs == 30_000)
  }

  @Test func gracefulMsIsTakenFromTheCommandLine() throws {
    #expect(try Run.parse(Self.required + ["--graceful-ms", "90000"]).gracefulMs == 90_000)
  }
}

/// `MacOSGuestSlot.acquire` reports two very different failures -- the host-policy ceiling and a
/// runtime directory it cannot lock in -- and both used to leave exit 75, which reads as "another
/// worker owns this instance". The mapping is pure so it can be pinned without a VM.
@Suite struct WorkerExitCodeTests {
  @Test func macOSGuestLimitGetsItsOwnExitCode() {
    #expect(Run.exitCode(forSlotFailure: VMError.macOSGuestLimitReached(limit: 2))
      == .macOSGuestLimitReached)
    #expect(WorkerExitCode.macOSGuestLimitReached.rawValue == 80)
  }

  @Test func anyOtherSlotFailureStaysLockHeld() {
    let failures: [any Error] = [
      VMError.workerLockHeldByOtherProcess(path: "/tmp/macos-slot-0.lock"),
      WorkerLockError.posix(operation: "open", errno: EACCES),
      CocoaError(.fileWriteNoPermission),
    ]
    for failure in failures {
      #expect(Run.exitCode(forSlotFailure: failure) == .lockHeld, "\(failure)")
    }
  }
}
