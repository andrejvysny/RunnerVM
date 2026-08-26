import Logging
import RunnerCore

/// Builds the standard observability-ID metadata keys so a job can be traced
/// through demand → clone → boot → agent → JIT → job → cleanup → delete
/// without manually correlating timestamps (spec §117).
public enum LogContext {
  public static func metadata(
    profile: RunnerProfileID? = nil,
    instance: InstanceID? = nil,
    session: RunnerSessionID? = nil,
    githubJobRequestID: String? = nil,
    operation: OperationID? = nil,
    workerPID: Int32? = nil,
    imageDigest: ImageDigest? = nil
  ) -> Logger.Metadata {
    var result: Logger.Metadata = [:]
    if let profile { result["profile_id"] = .string(profile.rawValue) }
    if let instance { result["instance_id"] = .string(instance.rawValue) }
    if let session { result["runner_session_id"] = .string(session.rawValue) }
    if let githubJobRequestID { result["github_job_request_id"] = .string(githubJobRequestID) }
    if let operation { result["operation_id"] = .string(operation.rawValue) }
    if let workerPID { result["worker_pid"] = .stringConvertible(workerPID) }
    if let imageDigest { result["image_digest"] = .string(imageDigest.rawValue) }
    return result
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
    imageDigest: ImageDigest? = nil
  ) -> Logger.Metadata {
    LogContext.metadata(
      profile: profile,
      instance: instance,
      session: session,
      githubJobRequestID: githubJobRequestID,
      operation: operation,
      workerPID: workerPID,
      imageDigest: imageDigest
    )
  }
}
