import Foundation
import Logging
import RunnerCore

/// Builds the standard observability-ID metadata keys so a job can be traced
/// through demand → clone → boot → agent → JIT → job → cleanup → delete
/// without manually correlating timestamps (spec §117).
///
/// The key names are API: `docs/logging.md` documents them, and the shipped Vector and
/// Fluent Bit pipelines index on them.
public enum LogContext {
  public static func metadata(
    profile: RunnerProfileID? = nil,
    instance: InstanceID? = nil,
    session: RunnerSessionID? = nil,
    githubJobRequestID: String? = nil,
    operation: OperationID? = nil,
    workerPID: Int32? = nil,
    imageDigest: ImageDigest? = nil,
    host: HostID? = nil,
    scaleSetID: String? = nil,
    githubRunnerID: Int64? = nil,
    githubRunnerName: String? = nil,
    githubRequestID: String? = nil
  ) -> Logger.Metadata {
    var result: Logger.Metadata = [:]
    if let profile { result["profile_id"] = .string(profile.rawValue) }
    if let instance { result["instance_id"] = .string(instance.rawValue) }
    if let session { result["runner_session_id"] = .string(session.rawValue) }
    if let githubJobRequestID { result["github_job_request_id"] = .string(githubJobRequestID) }
    if let operation { result["operation_id"] = .string(operation.rawValue) }
    if let workerPID { result["worker_pid"] = .stringConvertible(workerPID) }
    if let imageDigest { result["image_digest"] = .string(imageDigest.rawValue) }
    if let host { result["host_id"] = .string(host.rawValue) }
    if let scaleSetID { result["scale_set_id"] = .string(scaleSetID) }
    if let githubRunnerID { result["github_runner_id"] = .stringConvertible(githubRunnerID) }
    if let githubRunnerName { result["github_runner_name"] = .string(githubRunnerName) }
    if let githubRequestID { result["github_request_id"] = .string(githubRequestID) }
    return result
  }

  // MARK: - Process-wide context

  /// Metadata every entry carries, whatever logger emits it. `DaemonRuntime` publishes the host id
  /// here once it has loaded one, so a log shipper can attribute a line to a host without the
  /// hundreds of call sites each remembering to pass it.
  ///
  /// Merged by ``JSONLogHandler`` at the *lowest* priority: an explicit `host_id` at a call site,
  /// or on the handler, still wins.
  public static var global: Logger.Metadata { GlobalContext.shared.value }

  public static func setGlobal(_ metadata: Logger.Metadata) {
    GlobalContext.shared.value = metadata
  }

  /// Merges into whatever is already global rather than replacing it.
  public static func addGlobal(_ metadata: Logger.Metadata) {
    GlobalContext.shared.merge(metadata)
  }

  public static func setGlobalHost(_ id: HostID) {
    addGlobal(["host_id": .string(id.rawValue)])
  }

  public static func clearGlobal() {
    GlobalContext.shared.value = [:]
  }
}

/// Lock-protected process global. Deliberately not a task-local: the daemon's logging crosses
/// actor and `Task` boundaries constantly, and a task-local would silently vanish on every
/// detached `Task` the orchestrator spawns.
private final class GlobalContext: @unchecked Sendable {
  static let shared = GlobalContext()

  private let lock = NSLock()
  private var storage: Logger.Metadata = [:]

  var value: Logger.Metadata {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }

  func merge(_ other: Logger.Metadata) {
    lock.lock()
    storage.merge(other) { _, new in new }
    lock.unlock()
  }
}

extension Logger.Metadata {
  /// Convenience alias for `LogContext.metadata(...)` so call sites can write
  /// `Logger.Metadata.context(instance: ..., session: ...)`.
  public static func context(
    profile: RunnerProfileID? = nil,
    instance: InstanceID? = nil,
    session: RunnerSessionID? = nil,
    githubJobRequestID: String? = nil,
    operation: OperationID? = nil,
    workerPID: Int32? = nil,
    imageDigest: ImageDigest? = nil,
    host: HostID? = nil,
    scaleSetID: String? = nil,
    githubRunnerID: Int64? = nil,
    githubRunnerName: String? = nil,
    githubRequestID: String? = nil
  ) -> Logger.Metadata {
    LogContext.metadata(
      profile: profile,
      instance: instance,
      session: session,
      githubJobRequestID: githubJobRequestID,
      operation: operation,
      workerPID: workerPID,
      imageDigest: imageDigest,
      host: host,
      scaleSetID: scaleSetID,
      githubRunnerID: githubRunnerID,
      githubRunnerName: githubRunnerName,
      githubRequestID: githubRequestID
    )
  }
}
