import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// Turns a stopped builder VM into an immutable image (spec §62).
///
/// v1 is local only: the guest-side steps (remove transient runner configuration, temp files, SSH
/// host state) run inside the VM before it is stopped; this type covers the host-side half — prove
/// nothing is running, exclude host diagnostics, hash, and publish read-only.
public struct ImageSealer: Sendable {
  private let images: ImageStore
  private let logger: Logger

  public init(images: ImageStore, logger: Logger = Logger(component: .image)) {
    self.images = images
    self.logger = logger
  }

  public func seal(
    instanceDirectory: URL, as metadata: ImageMetadata, name: String? = nil
  ) async throws -> ImportedImage {
    // "Verify VM stopped": a held worker.lock means a live vmworker still owns these files, and a
    // disk hashed underneath a running guest would be torn.
    try WorkerLock.requireUnheld(at: VMInstanceLayout.workerLockPath(in: instanceDirectory))

    let disk = VMInstanceLayout.diskPath(in: instanceDirectory)
    guard FileSystem.exists(disk) else {
      throw ImageError.notFound(reference: disk.path(percentEncoded: false))
    }
    let nvramPath = VMInstanceLayout.nvramPath(in: instanceDirectory)
    let nvram = FileSystem.exists(nvramPath) ? nvramPath : nil

    // serial.log, worker.log and failure.json are host-side diagnostics (spec §74). They are simply
    // not layers, so they can never leak into a published image.
    let sealed = try await images.importLocal(disk: disk, nvram: nvram, metadata: metadata, name: name)
    logger.info(
      "image sealed",
      metadata: .context(imageDigest: sealed.digest).merging(["name": .string(name ?? "-")]) { $1 }
    )
    return sealed
  }
}
