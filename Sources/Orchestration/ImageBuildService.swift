import DaemonAPI

/// What `DaemonServiceImpl` needs from the in-daemon image builder. Phase 5 implements this;
/// until then `DaemonServiceImpl.builder` is `nil` and the five `image.build`/`build.*` methods
/// answer `ImageBuildError.unavailable`.
///
/// Kept in `Orchestration` (not `DaemonAPI`) because implementing it needs `Persistence`/
/// `ImageStore`/`WorkerProtocol`, none of which `DaemonAPI` may depend on.
public protocol ImageBuildService: Sendable {
  func start(_ request: ImageBuildRequest) async throws -> ImageBuildResponse
  func list() async throws -> [BuildInfoDTO]
  func get(id: String) async throws -> BuildInfoDTO
  func cancel(id: String) async throws -> BuildCancelResponse
  func readLog(id: String, offset: Int64, maxBytes: Int64) async throws -> BuildLogResponse
}
