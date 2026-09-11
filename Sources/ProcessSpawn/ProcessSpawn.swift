import Darwin
import Dispatch
import Foundation
import Synchronization

/// Runs one external command under a wall clock, an escalation ladder and a bounded drain.
///
/// Not "it always returns": `waitpid` on a leader wedged in an uninterruptible kernel wait (a
/// stuck `hdiutil` on an unresponsive disk, a process in `U` state) cannot be bounded from user
/// space -- `SIGKILL` itself is queued until the kernel call returns. What *is* guaranteed is that
/// nothing here waits on the child's cooperation: the ceiling, the signals and the reads all run
/// off the child's own behaviour, so every failure mode short of a wedged kernel call ends.
///
/// `Foundation.Process` offers none of that: no timeout, no way to reach a helper's children,
/// a `terminate()` that a child which inherited `SIG_IGN`/`SIGTERM` ignores, a raw `waitpid`
/// status exposed as `terminationStatus`, and drains that can only be done by blocking a thread
/// per pipe. Every one of those cost this daemon an incident, so the replacement is a `posix_spawn`
/// of its own:
///
/// * the child leads its own process group, so escalation is `kill(-pgid, …)` and reaches the
///   whole tree, not just the shell that was launched;
/// * `SIGTERM` at `timeout`, `SIGKILL` `killGrace` later, and no signal at all once the single
///   `waitpid` has reaped the leader -- and the same ladder runs when the *caller* is cancelled,
///   so `build cancel` releases its row within `killGrace` rather than at `build.timeout`
///   (see `SpawnControl`);
/// * the drain stops `drainGrace` after the leader exits even if something that escaped the group
///   still holds the pipe (see `PipeDrain`);
/// * the exit code is decoded, never the raw status.
///
/// Leaf module by design: `HostSetup` cannot depend on `Orchestration`, and both need this.
public enum ProcessSpawn {
  /// `onSpawn` is called synchronously with the leader's pid the moment it exists, before any
  /// output: the only window in which a caller can record a live process group somewhere durable
  /// (`MacOSProvisionStages`, so a daemon crash mid-provisioning leaves something findable).
  public static func run(
    _ request: SpawnRequest, onSpawn: (@Sendable (pid_t) -> Void)? = nil,
    onOutput: (@Sendable (String) -> Void)? = nil
  ) async throws -> SpawnResult {
    guard FileManager.default.isExecutableFile(atPath: request.executable) else {
      throw SpawnError.executableMissing(path: request.executable)
    }
    let control = SpawnControl()
    return try await withTaskCancellationHandler {
      let child = try Child.spawn(request, control: control)
      onSpawn?(child.pid)
      // A cooperative `Task`, never a GCD timer: under load every GCD thread can be parked in a
      // blocking drain and a timer queued behind them fires late (measured: an 11 s "300 ms"
      // deadline under `swift test --parallel`). Unstructured on purpose -- cancelling the caller
      // must not disarm the backstop that guarantees this call ends.
      let watchdog = Task {
        try await Task.sleep(for: request.timeout)
        control.signalGroup(SIGTERM, timedOut: true)
        try await Task.sleep(for: request.killGrace)
        control.signalGroup(SIGKILL, timedOut: true)
      }
      defer { watchdog.cancel() }
      return await child.collect(request: request, control: control, onOutput: onOutput)
    } onCancel: {
      // A flag plus a signal: `onCancel` can run before the spawn (the flag is replayed by
      // `started`), between the spawn and the wait, or after the leader is reaped (a no-op).
      control.cancel()
      // And then the same second rung the timeout ladder has. Without it a child that ignores
      // `SIGTERM` -- which is most of what this daemon shells out to, since they install `trap`
      // handlers -- would keep a cancelled build alive until its own `build.timeout`, forty
      // minutes later. Unstructured on purpose: this closure runs in an already-cancelled
      // context, where a structured sleep returns immediately.
      Task {
        try await Task.sleep(for: request.killGrace)
        control.signalGroup(SIGKILL)
      }
    }
  }

  /// `waitpid` status -> the number a human means by "exit code".
  ///
  /// `Process.terminationStatus` hands back the raw status on some paths, where "exited 1" reads as
  /// `256` and "killed by SIGKILL" as `9` -- indistinguishable from "exited 9". The shell
  /// convention is used instead, so a signal death is unambiguous: `128 + signal`.
  public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
    let low = status & 0o177
    if low == 0 { return (status >> 8) & 0xFF }   // WIFEXITED
    if low == 0o177 { return -1 }                 // WIFSTOPPED; never asked for, never expected
    return 128 + low                              // WIFSIGNALED
  }

  /// When `pid` was started, in microseconds since the epoch, or `nil` if no such process exists.
  ///
  /// A pid on its own is not an identity: the kernel hands it out again once the process is gone,
  /// and a recorded pid signalled after a restart can reach something entirely unrelated. A pid
  /// *plus* its start time is stable, and is what makes `kill(-pgid, …)` against a group recorded
  /// before a daemon crash safe to send.
  public static func startTime(of pid: pid_t) -> UInt64? {
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
    // A zero size means the pid is gone: `sysctl` succeeds and writes nothing.
    guard result == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_un.__p_starttime
    return UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)
  }
}

/// The spawned leader plus the descriptors this side owns.
struct Child: Sendable {
  var pid: pid_t
  /// Captured at spawn as `pid` (`POSIX_SPAWN_SETPGROUP`, pgroup 0) and never re-derived:
  /// `getpgid` answers `ESRCH` for a zombie leader while `kill(-pgid, …)` still works.
  var pgid: pid_t
  var stdoutRead: Int32
  var stderrRead: Int32
  /// `-1` when the child was given `/dev/null` for stdin.
  var stdinWrite: Int32
  var wakeRead: Int32
  var wakeWrite: Int32
  var input: [UInt8]

  static func spawn(_ request: SpawnRequest, control: SpawnControl) throws -> Child {
    let out = try makePipe()
    let err = try makePipe(closingOnFailure: [out.read, out.write])
    let wake = try makePipe(closingOnFailure: [out.read, out.write, err.read, err.write])
    var stdinPipe: (read: Int32, write: Int32)?
    if request.standardInput != nil {
      stdinPipe = try makePipe(
        closingOnFailure: [out.read, out.write, err.read, err.write, wake.read, wake.write])
    }

    // Every descriptor created above, minus the ones already closed. `posix_spawn_file_actions_init`
    // and `posix_spawnattr_init` can fail (ENOMEM), and a daemon that leaks four descriptors per
    // failed spawn runs out of them.
    var pending = Set([out.read, out.write, err.read, err.write, wake.read, wake.write])
    if let stdinPipe { pending.formUnion([stdinPipe.read, stdinPipe.write]) }
    var handedOff = false
    defer { if !handedOff { for fd in pending { close(fd) } } }
    func closeOnce(_ fd: Int32) {
      if pending.remove(fd) != nil { close(fd) }
    }

    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    var attributes = try SpawnAttributes(placement: .ownProcessGroup)
    defer { attributes.destroy() }
    if let stdinPipe {
      actions.duplicate(stdinPipe.read, onto: 0)
    } else {
      actions.open(0, path: "/dev/null", flags: O_RDONLY, mode: 0)
    }
    actions.duplicate(out.write, onto: 1)
    actions.duplicate(err.write, onto: 2)

    var pid: pid_t = 0
    let argv = [request.executable] + request.arguments
    let status = withCStrings(argv) { cArgv in
      withCStrings(environmentPairs(request.environment)) { cEnv in
        posix_spawn(&pid, request.executable, &actions.value, &attributes.value, cArgv, cEnv)
      }
    }
    // The child's ends are useless here and must be closed whatever happened: while this process
    // holds a copy of a write end, the matching read end never reaches EOF.
    closeOnce(out.write)
    closeOnce(err.write)
    if let stdinPipe { closeOnce(stdinPipe.read) }
    // Everything still pending is closed by the `defer` above.
    guard status == 0 else {
      throw SpawnError.spawnFailed(path: request.executable, code: status)
    }
    handedOff = true
    control.started(pgid: pid)
    return Child(
      pid: pid, pgid: pid, stdoutRead: out.read, stderrRead: err.read,
      stdinWrite: stdinPipe?.write ?? -1, wakeRead: wake.read, wakeWrite: wake.write,
      input: Array((request.standardInput ?? "").utf8))
  }

  /// Drains the pipes and reaps the leader, then answers exactly once.
  ///
  /// All three blocking steps run on Dispatch rather than in the calling task: `poll(2)`,
  /// `read(2)` and `waitpid(2)` would each park a cooperative-pool thread for as long as the
  /// helper runs, which starves every other task in the process (measured 2026-08-28 on CI's
  /// 3-thread pool).
  func collect(
    request: SpawnRequest, control: SpawnControl, onOutput: (@Sendable (String) -> Void)?
  ) async -> SpawnResult {
    // The absolute ceiling on this call: the timeout, plus the escalation ladder, plus the grace
    // in which a detached pipe holder may still be read.
    let hardDeadline = ContinuousClock.now
      .advanced(by: request.timeout + request.killGrace + request.drainGrace)
    let drained = Mutex(DrainOutcome(stdout: OutputCapture(limit: 0), stderr: OutputCapture(limit: 0)))
    return await withCheckedContinuation { (continuation: CheckedContinuation<SpawnResult, Never>) in
      let queue = DispatchQueue.global(qos: .utility)
      let group = DispatchGroup()
      queue.async(group: group) {
        let outcome = PipeDrain.run(
          stdout: stdoutRead, stderr: stderrRead, wake: wakeRead, stdinWrite: stdinWrite,
          input: input, hardDeadline: hardDeadline, drainGrace: request.drainGrace,
          captureLimit: request.captureLimit, control: control, onOutput: onOutput)
        drained.withLock { $0 = outcome }
      }
      queue.async(group: group) {
        Self.awaitExit(of: pid)
        control.reap(pid: pid, at: .now)
        // Wakes the drain loop so it shortens its deadline to `exit + drainGrace` instead of
        // sitting on the hard one.
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
      }
      group.notify(queue: queue) {
        close(wakeRead)
        close(wakeWrite)
        let outcome = drained.withLock { $0 }
        let state = control.snapshot
        continuation.resume(
          returning: SpawnResult(
            exitCode: state.exitCode ?? -1,
            stdout: outcome.stdout.text,
            stderr: outcome.stderr.text,
            timedOut: state.timedOut,
            cancelled: state.cancelled,
            outputTruncated: outcome.stdout.truncated || outcome.stderr.truncated,
            pid: pid,
            pgid: pgid))
      }
    }
  }

  /// Blocks until the child has exited, **without** reaping it (`WNOWAIT`).
  ///
  /// Deliberately not a plain `waitpid`: that would reap and free the pid in the same instant,
  /// and a `kill(-pgid, …)` already in flight on another thread could then land on whatever the
  /// kernel handed the number to next. Leaving the leader a zombie pins its pid until
  /// `SpawnControl.reap` collects it inside the lock that keeps every signal out.
  ///
  /// Returns as soon as the wait cannot be retried -- `ECHILD` means something else reaped the
  /// child, and looping on it would spin forever.
  private static func awaitExit(of pid: pid_t) {
    while true {
      var info = siginfo_t()
      if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 { return }
      if errno == EINTR { continue }
      return
    }
  }

  private static func makePipe(closingOnFailure: [Int32] = []) throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else {
      for fd in closingOnFailure { close(fd) }
      throw SpawnError.pipeFailed(code: errno)
    }
    // `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps only the descriptors a file action names, and
    // `adddup2(fd, fd)` is a no-op that leaves `FD_CLOEXEC` set -- the child would find that
    // descriptor closed. Only reachable when this process was started with one of 0/1/2 closed,
    // and cheap enough to rule out rather than reason about.
    var read = fds[0]
    var write = fds[1]
    if read < 3 || write < 3 {
      let movedRead = read < 3 ? fcntl(read, F_DUPFD, 3) : read
      let movedWrite = write < 3 ? fcntl(write, F_DUPFD, 3) : write
      if read < 3 { close(read) }
      if write < 3 { close(write) }
      guard movedRead >= 0, movedWrite >= 0 else {
        if movedRead >= 0 { close(movedRead) }
        if movedWrite >= 0 { close(movedWrite) }
        for fd in closingOnFailure { close(fd) }
        throw SpawnError.pipeFailed(code: errno)
      }
      read = movedRead
      write = movedWrite
    }
    return (read, write)
  }
}
