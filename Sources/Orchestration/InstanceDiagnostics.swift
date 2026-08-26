import Foundation
import GuestControl
import ImageStore
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Everything that has to survive a VM (spec §74, §131).
///
/// Two halves. `preserveInstanceLogs` moves the host-side evidence (`serial.log`, `worker.log`,
/// `failure.json`) out of the instance directory before that directory is unlinked;
/// `collectGuestDiagnostics` reaches *into* the guest for the runner's own `_diag` directory
/// before an ephemeral VM is destroyed, which is the only window in which those files exist.
///
/// Neither may ever fail a teardown. A VM that will not give up its logs still has to go away.
extension InstanceManager {
  /// The command run in the guest. Written as one `sh -c` script rather than several execs so the
  /// whole collection costs a single round trip and a single timeout, and so a missing `_diag`,
  /// journal or `dmesg` degrades to a smaller tarball instead of an error.
  ///
  /// stdout is the gzip stream itself: `agent.exec` chunks carry `data` as base64 on the wire
  /// (`ExecChunk.data` is `Data`, `Proto/guest_agent.md`), so binary needs no extra encoding.
  static func diagnosticsScript(unit: String) -> String {
    """
    set -u
    t=$(mktemp -d /tmp/rvm-diag.XXXXXX) || exit 1
    trap 'rm -rf "$t"' EXIT
    for d in /opt/actions-runner /home/*/actions-runner /root/actions-runner \
             /Users/*/actions-runner; do
      if [ -d "$d/_diag" ]; then cp -R "$d/_diag" "$t/_diag" 2>/dev/null; break; fi
    done
    journalctl -u \(unit) --no-pager -o short-iso -n 5000 > "$t/guest-agent.log" 2>/dev/null || true
    dmesg 2>/dev/null | tail -n 2000 > "$t/dmesg.log" 2>/dev/null || true
    tar czf - -C "$t" . 2>/dev/null
    """
  }

  /// The systemd unit in `GuestAgent/packaging/systemd/runnervm-guest-agent.service`.
  static let guestAgentUnit = "runnervm-guest-agent"

  static let diagnosticsArchiveName = "runner-diag.tar.gz"

  // MARK: - Guest-side collection

  /// Streams the guest's diagnostics tarball into `logs/instances/<id>/diag/runner-diag.tar.gz`.
  ///
  /// Returns the bytes written, or `nil` when nothing was collected. Every failure — collection
  /// disabled, agent unreachable, exec timeout, output cap, unwritable file — is a warning and
  /// nothing else: the caller is on the teardown path.
  @discardableResult
  func collectGuestDiagnostics(_ record: InstanceRecord) async -> Int? {
    let config = loggingConfiguration()
    guard config.collectRunnerDiagnostics else { return nil }
    guard let client = try? await agentClient(record.id) else { return nil }
    let destination = paths.instanceDiagnosticsDir(record.id)
      .appending(path: Self.diagnosticsArchiveName)
    do {
      let bytes = try await withDeadline(config.diagnosticsTimeout) { [self] in
        try await Self.stream(
          from: client, into: destination, timeout: config.diagnosticsTimeout,
          cap: LoggingConfig.maxDiagnosticsBytes, logger: logger, instance: record.id)
      }
      logger.info(
        "guest diagnostics collected",
        metadata: .context(profile: record.profileId, instance: record.id, host: hostId)
          .merging(["bytes": .stringConvertible(bytes)]) { $1 })
      await events?.record(
        LifecycleEventLog.diagnosticsCollected,
        LifecycleEventLog.Fields(
          instance: record.id, profile: record.profileId, to: "collected",
          reason: "\(bytes) bytes"))
      return bytes
    } catch {
      try? FileManager.default.removeItem(at: destination)
      logger.warning(
        "guest diagnostics collection failed",
        metadata: .context(profile: record.profileId, instance: record.id, host: hostId)
          .merging(["error": .string(Orchestrator.describe(error))]) { $1 })
      return nil
    }
  }

  /// Reads the exec stream into the file. Split out of `collectGuestDiagnostics` so that function
  /// stays under the size budget and so the byte cap lives next to the write that enforces it.
  private static func stream(
    from client: GuestAgentClient, into destination: URL, timeout: DurationValue, cap: Int64,
    logger: Logger, instance: InstanceID
  ) async throws -> Int {
    let request = ExecRequest(
      argv: ["/bin/sh", "-c", diagnosticsScript(unit: guestAgentUnit)],
      timeoutMs: max(1_000, timeout.duration.milliseconds),
      maxOutputBytes: cap)
    let events = try await client.exec(request)
    let manager = FileManager.default
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o750)])
    try? manager.removeItem(at: destination)
    guard manager.createFile(
      atPath: destination.path(percentEncoded: false), contents: nil,
      attributes: [.posixPermissions: NSNumber(value: 0o640)])
    else { throw DiagnosticsError.unwritable(path: destination.path(percentEncoded: false)) }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    var written = 0
    for try await event in events {
      switch event {
      case .stdout(let chunk):
        guard written + chunk.count <= Int(cap) else {
          throw DiagnosticsError.tooLarge(cap: cap)
        }
        try handle.write(contentsOf: chunk)
        written += chunk.count
      case .stderr(let chunk):
        // The script silences its own failures, so anything here is worth one debug line.
        guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { continue }
        logger.debug(
          "guest diagnostics stderr", metadata: .context(instance: instance)
            .merging(["output": .string(text)]) { $1 })
      case .exited(let code):
        guard code == 0 else { throw DiagnosticsError.execFailed(exitCode: code) }
      }
    }
    guard written > 0 else { throw DiagnosticsError.empty }
    return written
  }

  // MARK: - Host-side preservation

  /// Moves `serial.log` / `worker.log` / `failure.json` into `logs/instances/<id>/`, which is not
  /// under `instances/` and therefore outlives `InstanceStore.delete`. A move rather than a copy:
  /// the source is about to be unlinked anyway, and both paths are on the state volume.
  func preserveInstanceLogs(_ id: InstanceID) {
    let source = paths.instanceDir(id)
    let destination = paths.instanceLogDir(id)
    let manager = FileManager.default
    guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
    try? manager.createDirectory(
      at: destination, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o750)])
    for name in VMInstanceLayout.diagnosticNames.sorted() {
      let from = source.appending(path: name)
      guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
      let to = destination.appending(path: name)
      try? manager.removeItem(at: to)
      // Rename first; a cross-volume layout (a bind-mounted logs directory) falls back to a copy.
      if (try? manager.moveItem(at: from, to: to)) == nil {
        try? manager.copyItem(at: from, to: to)
      }
    }
  }
}

enum DiagnosticsError: RunnerError {
  case execFailed(exitCode: Int32)
  case tooLarge(cap: Int64)
  case unwritable(path: String)
  case empty

  var code: String {
    switch self {
    case .execFailed: "DIAGNOSTICS_EXEC_FAILED"
    case .tooLarge: "DIAGNOSTICS_TOO_LARGE"
    case .unwritable: "DIAGNOSTICS_UNWRITABLE"
    case .empty: "DIAGNOSTICS_EMPTY"
    }
  }

  var message: String {
    switch self {
    case let .execFailed(exitCode): "the collection command exited \(exitCode)"
    case let .tooLarge(cap): "the archive exceeded \(ByteSize(bytes: UInt64(max(0, cap))))"
    case let .unwritable(path): "cannot create \(path)"
    case .empty: "the guest produced no diagnostics"
    }
  }

  var retryable: Bool { false }
}
