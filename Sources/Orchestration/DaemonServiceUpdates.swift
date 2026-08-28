import DaemonAPI
import Foundation
import Persistence
import RunnerCore

/// `image.update.check|run|status` (phase D6). Split out of `DaemonServiceImpl.swift` to keep that
/// file under its line budget, same discipline as `DaemonServiceBuild.swift`.
///
/// `status` deliberately reads `managed_images` directly rather than going through `updates`: the
/// table is the durable record, so a daemon whose update service is not wired in (the M1-M5 test
/// harness) still reports what this host tracks instead of failing.
extension DaemonServiceImpl {
  func imageUpdateCheck(
    _ request: ImageUpdateCheckRequest
  ) async throws -> ImageUpdateStatusResponse {
    let service = try requireUpdates()
    try await requireTrack(request.managed)
    return Self.response(await service.check(only: request.managed))
  }

  func imageUpdateRun(_ request: ImageUpdateRunRequest) async throws -> ImageUpdateStatusResponse {
    let service = try requireUpdates()
    try await requireTrack(request.managed)
    // Returns the pre-cycle snapshots, like `image.pull` answers before the transfer: a pull plus
    // a boot-to-idle qualification does not fit inside the socket's idle timeout.
    return Self.response(await service.startCycle(only: request.managed))
  }

  func imageUpdateStatus() async throws -> ImageUpdateStatusResponse {
    Self.response(try await managedRows.list().sorted { $0.name < $1.name })
  }

  /// The `Updates` block `runnerctl status` renders. `nil` rather than `[]` when this host tracks
  /// nothing, so the block is dropped entirely instead of printed empty.
  func updateTracks() async -> [ImageUpdateTrackDTO]? {
    guard let rows = try? await managedRows.list(), !rows.isEmpty else { return nil }
    return Self.response(rows.sorted { $0.name < $1.name }).tracks
  }

  private func requireUpdates() throws -> ImageUpdateService {
    guard let updates else { throw OrchestrationError.imageUpdatesUnavailable }
    return updates
  }

  /// A name that matches no row is a caller error, not an empty result: silently checking nothing
  /// looks exactly like checking successfully.
  private func requireTrack(_ name: String?) async throws {
    guard let name else { return }
    guard try await managedRows.get(name: name) != nil else {
      throw OrchestrationError.managedImageUnknown(name: name)
    }
  }

  static func response(_ rows: [ManagedImageRecord]) -> ImageUpdateStatusResponse {
    ImageUpdateStatusResponse(
      tracks: rows.map {
        ImageUpdateTrackDTO(
          name: $0.name,
          kind: $0.kind.rawValue,
          sourceReference: $0.sourceReference,
          lastSourceDigest: $0.lastSourceDigest,
          currentImageDigest: $0.currentImageDigest?.rawValue,
          candidateImageDigest: $0.candidateImageDigest?.rawValue,
          state: $0.state.rawValue,
          lastCheckedAt: $0.lastCheckedAt.map { RFC3339.string(from: $0.date) },
          lastUpdatedAt: $0.lastUpdatedAt.map { RFC3339.string(from: $0.date) },
          lastError: $0.lastError,
          autoUpdate: $0.autoUpdate)
      })
  }
}
