import DaemonAPI
import Foundation
import ImageBuild
import Persistence
import RunnerCore

/// `image_builds` row ⇄ `BuildInfoDTO`, and the small conversions `ImageBuilder` needs between the
/// recipe model and the persisted columns. Kept out of `Mapping.swift` so the build surface can
/// move without touching the instance/image DTO mappers.
enum BuildMapping {
  static func info(_ record: ImageBuildRecord) -> BuildInfoDTO {
    BuildInfoDTO(
      buildId: record.id.rawValue,
      name: record.name,
      state: record.state.rawValue,
      operationId: record.operationId?.rawValue,
      pushReference: record.pushReference,
      pushOperationId: record.pushOperationId?.rawValue,
      recipePath: record.recipePath,
      recipeSHA256: record.recipeSHA256,
      contextPath: record.contextPath,
      contextSHA256: record.contextSHA256,
      fromKind: record.fromKind.rawValue,
      fromReference: record.fromReference,
      baseDigest: record.baseDigest?.rawValue,
      baseSHA256: record.baseSHA256,
      cpuCount: record.cpuCount,
      memoryBytes: record.memoryBytes,
      diskBytes: record.diskBytes,
      diskReservationBytes: record.diskReservationBytes,
      timeoutMs: record.timeoutMs,
      buildPath: record.buildPath,
      logPath: record.logPath,
      workerPid: record.workerPid,
      totalSteps: record.totalSteps,
      currentStep: record.currentStep,
      currentInstruction: record.currentInstruction,
      imageDigest: record.imageDigest?.rawValue,
      failureCode: record.failureCode,
      failureMessage: record.failureMessage,
      createdAt: RFC3339.string(from: record.createdAt.date),
      startedAt: record.startedAt.map { RFC3339.string(from: $0.date) },
      finishedAt: record.finishedAt.map { RFC3339.string(from: $0.date) },
      recoverySince: record.recoverySince.map { RFC3339.string(from: $0.date) },
      updatedAt: RFC3339.string(from: record.updatedAt.date))
  }

  /// The `from_kind`/`from_reference` pair a `FROM` line persists as. `cloudImage` keeps the
  /// location alone; its digest travels in `base_sha256`, which is what a rebuild verifies against.
  static func from(_ source: RecipeFrom.Source) -> (kind: ImageBuildFromKind, reference: String) {
    switch source {
    case let .localImage(reference): (.image, reference)
    case let .registry(reference): (.registry, reference)
    case let .cloudImage(location, _): (.cloudImage, location)
    }
  }

  static func argsJSON(_ args: [String: String]) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  /// `RunnerError` is what every caller downstream reports; anything else (a GRDB failure, a
  /// cancellation) still has to land in `failure_code`/`failure_message` as something readable.
  static func failure(_ error: any Error) -> (code: String, message: String) {
    if error is CancellationError { return (ImageBuildError.cancelled.code, ImageBuildError.cancelled.message) }
    guard let runnerError = error as? any RunnerError else {
      return ("BUILD_FAILED", String(describing: error))
    }
    return (runnerError.code, runnerError.message)
  }
}
