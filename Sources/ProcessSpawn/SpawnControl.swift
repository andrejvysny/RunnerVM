import Darwin
import Synchronization

/// The one piece of shared state a spawn has, and the only thing allowed to signal the child.
///
/// Three writers race here: the caller's task (cancellation), the watchdog tasks (the timeout and
/// cancel ladders) and the wait thread (the reaping). The invariant every one of them depends on
/// is that **no signal is ever sent after the leader has been reaped**: a reaped pid is free for
/// the kernel to hand out again, and `kill(-pgid, SIGKILL)` against a recycled group id would kill
/// an unrelated process tree.
///
/// Holding the lock across the state check and the `kill(2)` is only half of that. The other half
/// is that the reap itself happens *inside* the same critical section: the wait thread learns the
/// leader exited with `waitid(…, WEXITED | WNOWAIT)`, which leaves it a zombie -- and a zombie's
/// pid cannot be reused -- and only then takes the lock to collect the status with
/// `waitpid(…, WNOHANG)` and close the state machine. A signal that got the lock first is
/// delivered to a group that still exists; one that gets it afterwards sees `.reaped` and sends
/// nothing.
final class SpawnControl: Sendable {
  private struct State: Sendable {
    var phase: Phase = .pendingSpawn(cancelled: false)
    var timedOut = false
    var cancelled = false
    var exitedAt: ContinuousClock.Instant?
    /// `nil` means the status could never be collected (`waitpid` answered `ECHILD`).
    var exitCode: Int32?
  }

  private enum Phase: Sendable {
    case pendingSpawn(cancelled: Bool)
    case running(pgid: pid_t)
    case reaped
  }

  /// Written once the child exists so the drain loop notices its exit without polling for it.
  struct Snapshot: Sendable {
    var timedOut: Bool
    var cancelled: Bool
    var exitedAt: ContinuousClock.Instant?
    var exitCode: Int32?
  }

  private let state = Mutex(State())

  /// Cancellation before the spawn cannot signal anything, so it is remembered instead; `started`
  /// replays it the moment there is a process group to aim at. The `SIGKILL` that follows
  /// `killGrace` later is armed by the caller (`ProcessSpawn.run`), so a child that ignores
  /// `SIGTERM` cannot hold a cancelled `build cancel` open until the build's own timeout.
  func cancel() {
    state.withLock { current in
      current.cancelled = true
      switch current.phase {
      case .pendingSpawn:
        current.phase = .pendingSpawn(cancelled: true)
      case let .running(pgid):
        kill(-pgid, SIGTERM)
      case .reaped:
        break
      }
    }
  }

  /// Publishes the live process group. The pgid is the value captured at spawn (`pgid == pid`),
  /// never a `getpgid` result.
  func started(pgid: pid_t) {
    state.withLock { current in
      let wasCancelled: Bool
      if case let .pendingSpawn(cancelled) = current.phase { wasCancelled = cancelled } else {
        wasCancelled = false
      }
      current.phase = .running(pgid: pgid)
      if wasCancelled { kill(-pgid, SIGTERM) }
    }
  }

  /// The flag is set *inside* the guard: a child that finished microseconds before its deadline
  /// is reaped first, and marking it `timedOut` because the watchdog task woke up a moment later
  /// would report a clean run as a killed one.
  func signalGroup(_ signal: Int32, timedOut: Bool = false) {
    state.withLock { current in
      guard case let .running(pgid) = current.phase else { return }
      if timedOut { current.timedOut = true }
      kill(-pgid, signal)
    }
  }

  /// Collects the exited leader's status and closes the state machine in one critical section.
  ///
  /// The caller must already have established that `pid` has exited *without* reaping it
  /// (`waitid` with `WNOWAIT`), so the `waitpid` below cannot block and the pid cannot have been
  /// recycled behind a signal that is waiting on this lock. Returns `nil` when the status could
  /// not be collected at all -- `ECHILD`, meaning something else reaped it.
  @discardableResult
  func reap(pid: pid_t, at instant: ContinuousClock.Instant) -> Int32? {
    state.withLock { current in
      var status: Int32 = 0
      let collected = waitpid(pid, &status, WNOHANG)
      let code = collected == pid ? ProcessSpawn.exitCode(fromWaitStatus: status) : nil
      current.phase = .reaped
      current.exitedAt = instant
      current.exitCode = code
      return code
    }
  }

  var snapshot: Snapshot {
    state.withLock {
      Snapshot(
        timedOut: $0.timedOut, cancelled: $0.cancelled, exitedAt: $0.exitedAt,
        exitCode: $0.exitCode)
    }
  }
}
