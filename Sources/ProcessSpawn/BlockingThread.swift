import Foundation

/// Runs blocking work on a thread of its own.
///
/// Neither the cooperative pool nor `DispatchQueue.global` is a safe home for a call that can
/// block for seconds. The first starves every task in the process; the second admits a new
/// low-QoS thread only while fewer than about one-per-CPU are busy -- on CI's 3-vCPU runner
/// (2026-09-11) `.utility` blocks waited ~40 s for a thread under `swift test --parallel`, so
/// every spawn's drain and wait started after its watchdog had already fired. A dedicated
/// `Thread` starts at once; one short-lived thread per call is cheap at this daemon's rates.
public enum BlockingThread {
  /// Runs `body` on a new thread and returns its result.
  public static func run<T: Sendable>(
    name: String, _ body: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      start(name: name) { continuation.resume(returning: body()) }
    }
  }

  /// Starts `body` on a new thread and returns immediately.
  public static func start(name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.start()
  }
}
