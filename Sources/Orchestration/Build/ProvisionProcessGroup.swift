import Darwin
import Foundation
import Logging
import ProcessSpawn

/// The macOS provisioning script's process group, recorded on disk for the length of one run.
///
/// `provision-macos-tart.sh` drives a live guest over SSH for up to forty minutes. If runnerd dies
/// in that window the script is reparented to launchd and keeps going against a VM nobody owns any
/// more -- it is not a child of the restarted daemon, it holds no lock, and nothing else in the
/// system knows it exists. This marker is the only handle recovery has on it.
///
/// A recorded pid on its own would not be safe to signal after a restart: the kernel hands pids
/// out again, and `kill(-pgid, …)` against a recycled group id reaches an unrelated process tree.
/// The leader's start time is recorded alongside it and has to match exactly before anything is
/// sent, which makes the pair an identity rather than a guess.
enum ProvisionProcessGroup {
  static let fileName = "provision.pgid"

  static func marker(in work: URL) -> URL {
    work.appending(path: fileName)
  }

  /// Written synchronously from inside the spawn, so the marker exists before the script's first
  /// line of output does -- a crash one millisecond into the run is still recoverable.
  static func record(_ pid: pid_t, in work: URL) {
    guard let started = ProcessSpawn.startTime(of: pid) else { return }
    try? Data("\(pid) \(started)\n".utf8).write(to: marker(in: work), options: .atomic)
  }

  static func clear(in work: URL) {
    try? FileManager.default.removeItem(at: marker(in: work))
  }

  /// `SIGTERM` to the recorded group, once, and only if it is still the process that was recorded.
  /// Returns the pgid that was signalled.
  ///
  /// `SIGTERM` and nothing else: the script installs `trap cleanup EXIT`, and its own
  /// `RVM_PROVISION_TIMEOUT` is the backstop for a run that ignores the signal. A reconcile tick
  /// has nothing to wait on, so there is no second rung to this ladder.
  @discardableResult
  static func terminate(in work: URL, logger: Logger) -> pid_t? {
    let url = marker(in: work)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    // Removed whatever the outcome: a marker that no longer matches a live process is stale, and
    // one that does has now been signalled.
    defer { try? FileManager.default.removeItem(at: url) }
    let fields = text.split(separator: " ")
    // Never this daemon's own group, whatever the file says: a recycled pid that landed on
    // runnerd, or a marker written by a test double, must not make it `SIGTERM` itself.
    guard fields.count == 2, let pgid = pid_t(fields[0]), pgid > 1,
          pgid != getpgrp(), pgid != getpid(),
          let recorded = UInt64(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    guard ProcessSpawn.startTime(of: pgid) == recorded else {
      // The leader is gone but its group may not be: `ssh` and `expect` outlive the shell that
      // started them, and `kill(-pgid, …)` on a group whose leader has been reaped is not safe to
      // send -- the pid may already name something else. Say so rather than report a clean sweep.
      logger.warning(
        """
        an orphaned macOS provisioning script had already exited; its process group was left \
        alone (a surviving ssh or expect under it will not have been signalled)
        """,
        metadata: ["pgid": .stringConvertible(pgid)])
      return nil
    }
    guard kill(-pgid, SIGTERM) == 0 else { return nil }
    return pgid
  }
}
