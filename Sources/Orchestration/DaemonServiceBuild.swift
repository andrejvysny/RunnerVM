import DaemonAPI
import RunnerCore

/// `image.build` / `build.*`. Split out of `DaemonServiceImpl.swift` to keep that file under its
/// line budget, same discipline as `DaemonServiceImages.swift`. Every method here just forwards to
/// `builder`, which is `nil` until Phase 5 lands the image builder itself.
extension DaemonServiceImpl {
  func imageBuild(_ request: ImageBuildRequest) async throws -> ImageBuildResponse {
    try await requireBuilder().start(request)
  }

  func buildList() async throws -> BuildListResponse {
    BuildListResponse(builds: try await requireBuilder().list())
  }

  func buildGet(_ request: BuildGetRequest) async throws -> BuildInfoDTO {
    try await requireBuilder().get(id: request.buildId)
  }

  func buildLog(_ request: BuildLogRequest) async throws -> BuildLogResponse {
    let maxBytes = min(request.maxBytes ?? BuildLogRequest.maxChunkBytes, BuildLogRequest.maxChunkBytes)
    return try await requireBuilder().readLog(id: request.buildId, offset: request.offset, maxBytes: maxBytes)
  }

  func buildCancel(_ request: BuildCancelRequest) async throws -> BuildCancelResponse {
    try await requireBuilder().cancel(id: request.buildId)
  }

  private func requireBuilder() throws -> any ImageBuildService {
    guard let builder else { throw ImageBuildError.unavailable }
    return builder
  }
}
