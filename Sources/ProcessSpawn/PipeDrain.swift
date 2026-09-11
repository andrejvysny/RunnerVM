import Darwin
import Foundation

/// Everything the drain thread produced.
struct DrainOutcome: Sendable {
  var stdout: OutputCapture
  var stderr: OutputCapture
}

/// Reads the child's stdout and stderr (and writes its stdin) on raw, non-blocking descriptors
/// against an absolute deadline.
///
/// Deliberately not `Pipe.availableData`: it throws an *ObjC* exception on a read error, which no
/// Swift `catch` can intercept, and it blocks with no way to stop. Deliberately not one blocking
/// reader per stream either -- the reason this is a single `poll(2)` loop is that both streams and
/// the leader's exit have to be watched at once:
///
/// * draining stdout to EOF before touching stderr deadlocks against a helper whose diagnostics
///   fill the 64 KiB stderr buffer first (the macOS provisioning script logs to stderr for forty
///   minutes);
/// * EOF on a pipe needs *every* copy of its write end closed, so a process that escaped the
///   leader's process group -- `expect` calls `setsid()` for what it spawns, and a `&`-backgrounded
///   grandchild that daemonises does the same -- keeps the pipe open after the group is killed and
///   would hang a read-to-EOF forever.
///
/// So the loop stops at `min(hardDeadline, leaderExit + drainGrace)` whether or not it saw EOF,
/// closes the descriptors it owns (stdout, stderr, the stdin write end) and returns what it read.
enum PipeDrain {
  /// Chunk size for one `read(2)`. A pipe buffer is 64 KiB, so a larger read never pays off.
  private static let bufferSize = 64 << 10

  /// Reads per stream per wake-up. A child writing faster than this side drains (`yes`, a tool
  /// looping on stderr) would otherwise keep the inner read loop fed forever and the deadline
  /// would never be re-evaluated.
  private static let chunksPerWake = 64

  static func run(
    stdout: Int32, stderr: Int32, wake: Int32, stdinWrite: Int32, input: [UInt8],
    hardDeadline: ContinuousClock.Instant, drainGrace: Duration, captureLimit: Int,
    control: SpawnControl, onOutput: (@Sendable (String) -> Void)?
  ) -> DrainOutcome {
    var out = Reader(fd: stdout, capture: OutputCapture(limit: captureLimit))
    var err = Reader(fd: stderr, capture: OutputCapture(limit: captureLimit))
    var wakeOpen = true
    var stdinOpen = stdinWrite >= 0
    var written = 0
    for fd in [stdout, stderr, wake] { setNonBlocking(fd) }
    if stdinOpen {
      setNonBlocking(stdinWrite)
      // The child may exit without reading its stdin; `SIGPIPE`'s default disposition would then
      // kill *this* process rather than fail the write.
      var on: Int32 = 1
      _ = fcntl(stdinWrite, F_SETNOSIGPIPE, &on)
    }
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while !out.done || !err.done {
      let now = ContinuousClock.now
      var stopAt = hardDeadline
      if let exited = control.snapshot.exitedAt {
        stopAt = min(stopAt, exited.advanced(by: drainGrace))
      }
      guard now < stopAt else { break }

      var descriptors: [pollfd] = []
      var roles: [Role] = []
      if !out.done {
        descriptors.append(pollfd(fd: stdout, events: Int16(POLLIN), revents: 0))
        roles.append(.stdout)
      }
      if !err.done {
        descriptors.append(pollfd(fd: stderr, events: Int16(POLLIN), revents: 0))
        roles.append(.stderr)
      }
      if wakeOpen {
        descriptors.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0))
        roles.append(.wake)
      }
      if stdinOpen {
        descriptors.append(pollfd(fd: stdinWrite, events: Int16(POLLOUT), revents: 0))
        roles.append(.stdin)
      }
      let waitMs = max(1, min(Int64(Int32.max), milliseconds(now.duration(to: stopAt))))
      let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(waitMs))
      if ready < 0 {
        if errno == EINTR { continue }
        break
      }
      guard ready > 0 else { continue }

      for (index, descriptor) in descriptors.enumerated() where descriptor.revents != 0 {
        switch roles[index] {
        case .stdout:
          out.consume(&buffer, onOutput: onOutput)
        case .stderr:
          err.consume(&buffer, onOutput: onOutput)
        case .wake:
          // One byte, written by the `waitpid` thread so this loop re-reads `exitedAt` and can
          // shorten its deadline the moment the leader is gone. `EAGAIN` is not a reason to stop
          // watching it -- dropping it would leave the loop sitting on the hard deadline while a
          // detached pipe holder keeps the pipes open.
          let count = buffer.withUnsafeMutableBytes { read(wake, $0.baseAddress, $0.count) }
          if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            wakeOpen = false
          }
        case .stdin:
          if !writeInput(stdinWrite, input, &written, revents: descriptor.revents) {
            close(stdinWrite)
            stdinOpen = false
          }
        }
      }
    }

    // The deadline stops the *waiting*, never the reading. This thread can start minutes late --
    // `DispatchQueue.global` grows its pool by roughly one thread per millisecond once every
    // existing one is busy, and a loaded host (a `swift test --parallel` run, a build with many
    // concurrent tools) routinely delays it past a short ceiling -- and a killed tool's last
    // words are usually the only diagnostic it leaves. So whatever the pipes still hold is taken
    // before the descriptors go: pipe contents outlive the writer, and this read cannot block.
    if !out.done { out.consume(&buffer, onOutput: onOutput) }
    if !err.done { err.consume(&buffer, onOutput: onOutput) }
    out.flush(onOutput: onOutput)
    err.flush(onOutput: onOutput)
    close(stdout)
    close(stderr)
    if stdinOpen { close(stdinWrite) }
    return DrainOutcome(stdout: out.capture, stderr: err.capture)
  }

  private enum Role { case stdout, stderr, wake, stdin }

  /// `false` once the write end is finished with (everything sent, or the child stopped reading).
  private static func writeInput(
    _ fd: Int32, _ input: [UInt8], _ written: inout Int, revents: Int16
  ) -> Bool {
    guard revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
    while written < input.count {
      let count = input.withUnsafeBytes { bytes -> Int in
        write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
      }
      if count > 0 {
        written += count
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        return true
      } else {
        return false
      }
    }
    return false
  }

  private static func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0 else { return }
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }

  /// One stream: everything read goes into `capture`, and whole lines go to `onOutput` as they
  /// arrive. Line-buffered on purpose -- a partial line handed to `build.log` would interleave
  /// with the other stream's output mid-word.
  private struct Reader {
    /// A stream with no newline in it still has to reach `onOutput` eventually; without this a
    /// tool that writes progress with `\r` would buffer its whole run in memory.
    private static let maxPendingLine = 1 << 20

    let fd: Int32
    var capture: OutputCapture
    var done = false
    private var pending = Data()

    init(fd: Int32, capture: OutputCapture) {
      self.fd = fd
      self.capture = capture
    }

    mutating func consume(_ buffer: inout [UInt8], onOutput: (@Sendable (String) -> Void)?) {
      for _ in 0..<PipeDrain.chunksPerWake {
        let count = buffer.withUnsafeMutableBytes { bytes in read(fd, bytes.baseAddress, bytes.count) }
        if count > 0 {
          buffer.withUnsafeBytes { bytes in
            capture.append(UnsafeRawBufferPointer(rebasing: bytes[0..<count]))
            if onOutput != nil { pending.append(contentsOf: bytes[0..<count]) }
          }
          emitLines(onOutput)
          continue
        }
        if count < 0, errno == EINTR { continue }
        // `EAGAIN` only means "nothing right now"; anything else (including 0, which is EOF) is
        // the end of this stream.
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
        done = true
        return
      }
    }

    mutating func flush(onOutput: (@Sendable (String) -> Void)?) {
      guard let onOutput, !pending.isEmpty else { return }
      onOutput(String(decoding: pending, as: UTF8.self))
      pending.removeAll()
    }

    private mutating func emitLines(_ onOutput: (@Sendable (String) -> Void)?) {
      guard let onOutput else { return }
      while let newline = pending.firstIndex(of: 0x0A) {
        onOutput(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
        pending = pending[pending.index(after: newline)...]
      }
      if pending.count > Self.maxPendingLine {
        onOutput(String(decoding: pending, as: UTF8.self))
        pending.removeAll()
      }
    }
  }
}

/// `Duration` in whole milliseconds, rounded down.
func milliseconds(_ duration: Duration) -> Int64 {
  let parts = duration.components
  return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
}
