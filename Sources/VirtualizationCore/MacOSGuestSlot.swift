import Foundation
import RunnerCore

/// The second fence on `HostConstants.macOSGuestLimit`.
///
/// runnerd already refuses to admit a third macOS instance (`CapacityCalculator`), and that is the
/// check operators see. This one is host policy rather than scheduling: at most two macOS guests
/// may run on an Apple-branded Mac, and the limit has to hold even when the scheduler is not the
/// thing starting the VM -- a second runnerd against the same runtime directory, a recovery path
/// that mis-counts, an operator running `vmworker run` by hand.
///
/// One `fcntl` record lock per slot, in the shared runtime directory, held for the worker's whole
/// life exactly like `worker.lock`. The kernel drops it when the process dies, so a crashed worker
/// never leaks a slot and no reaper is needed.
public enum MacOSGuestSlot {
  public static func lockName(_ index: Int) -> String { "macos-slot-\(index).lock" }

  /// Takes the lowest free slot in `runtimeDirectory`.
  ///
  /// - Throws: `VMError.macOSGuestLimitReached` when every slot is held by a live process. That is
  ///   the retryable error the daemon already understands, because the honest answer is "not now",
  ///   not "never".
  public static func acquire(
    in runtimeDirectory: URL, limit: Int = HostConstants.macOSGuestLimit
  ) throws -> WorkerLock {
    var lastFailure: (any Error)?
    for index in 0..<max(0, limit) {
      let url = runtimeDirectory.appending(path: lockName(index))
      do {
        return try WorkerLock.acquire(url: url)
      } catch WorkerLockError.held {
        continue
      } catch {
        // An unwritable runtime directory is a host problem, not a busy slot: remember it and keep
        // trying the remaining slots, then report it instead of a misleading "limit reached".
        lastFailure = error
      }
    }
    if let lastFailure { throw lastFailure }
    throw VMError.macOSGuestLimitReached(limit: limit)
  }
}
