import DaemonAPI
import RunnerCore

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

  /// Hand the builder the applied configuration, the same way `images`/`instances`/`gateway`/
  /// `orchestrator` get it. Without this the builder answers from `ImageBuildConfig()` and
  /// `HostConfig.Reserve()` forever: the whole `build:` block is ignored, and the default 50 GiB
  /// disk reserve refuses every build on a host configured for a smaller floor (seen live --
  /// "needs 24GiB, only 15.5GiB free" on a host with 65.5 GiB free and `host.reserve.disk: 4GiB`).
  ///
  /// Deliberately no default implementation: a protocol-extension no-op outranks the actor's own
  /// method at a concrete call site, so `ImageBuilder` would silently keep its default
  /// configuration even where the caller holds the concrete type (it did -- the build harness's
  /// own `updateConfiguration` became a no-op and four lifecycle tests started failing).
  func updateConfiguration(_ config: RunnerConfiguration?) async
}
