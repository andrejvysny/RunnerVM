import Foundation
import ImageStore
import RunnerCore

/// Local image-store consistency (spec WP9): every manifest still points at a blob that is
/// actually there and the right size, and at least one locally stored image can actually run a
/// job. Reads `images/` directly through `ImageStore` rather than the daemon, so both checks work
/// even when runnerd is not running -- doctor's whole point is to catch problems before the
/// daemon needs to.
extension DoctorChecks {
  // MARK: - image_store_integrity

  /// `--deep` also re-hashes every blob's sha256 against its manifest (`ImageStore.verify`); off
  /// by default because hashing a multi-GiB disk image is slow and this check otherwise runs on
  /// every `doctor` invocation.
  static func imageStoreIntegrity(paths: RunnerPaths, deep: Bool) async -> DoctorCheck {
    let id = "image_store_integrity"
    let title = "Image store integrity"
    let store = ImageStore(paths: paths)
    let images: [ImageInfo]
    do {
      images = try await store.list()
    } catch {
      return DoctorCheck(
        id: id, title: title, status: .warn, detail: "could not list local images: \(error)")
    }
    guard !images.isEmpty else {
      return DoctorCheck(id: id, title: title, status: .ok, detail: "no local images stored")
    }
    var checked = 0
    for image in images {
      guard let layer = image.manifest.layer(.disk) else { continue }
      checked += 1
      let actual = await blobSize(store: store, digest: image.digest, role: .disk)
      let layerCheck = DoctorImageIntegrity.LayerCheck(
        digest: layer.digest, recordedBytes: layer.sizeBytes, actualBytes: actual)
      if let problem = layerCheck.problem {
        return DoctorCheck(
          id: id, title: title, status: .fail,
          detail: "\(image.digest.rawValue): \(problem) (stopped after \(checked)/\(images.count))"
        )
      }
      guard deep else { continue }
      do {
        try await store.verify(digest: image.digest)
      } catch {
        return DoctorCheck(
          id: id, title: title, status: .fail,
          detail: "\(image.digest.rawValue) failed sha256 verification: \(error)"
        )
      }
    }
    let mode = deep ? "size + sha256 re-hash" : "size only (pass --deep for a full re-hash)"
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(checked) image(s) checked (\(mode)), all consistent"
    )
  }

  private static func blobSize(
    store: ImageStore, digest: ImageDigest, role: LocalImageManifest.LayerRole
  ) async -> UInt64? {
    guard let url = try? await store.blobURL(role: role, digest: digest) else { return nil }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    return size?.uint64Value
  }

  // MARK: - guest_agent_image

  /// `profile_image_guest_agent` (`DoctorConfigChecks.swift`) only grades images a configured
  /// profile actually references, over the daemon connection, and is vacuously OK with zero
  /// profiles or an unreachable daemon. This checks the local store directly: does *anything*
  /// here carry a guest agent at all, which is what a fresh host needs before any profile can ever
  /// run a job.
  static func guestAgentImage(paths: RunnerPaths) async -> DoctorCheck {
    let id = "guest_agent_image"
    let title = "Guest agent image"
    let store = ImageStore(paths: paths)
    let images: [ImageInfo]
    do {
      images = try await store.list()
    } catch {
      return DoctorCheck(
        id: id, title: title, status: .warn, detail: "could not list local images: \(error)")
    }
    guard !images.isEmpty else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "no local images stored yet; nothing can run a job until one is imported or built"
      )
    }
    let withAgent = images.filter(\.metadata.hasGuestAgent).count
    guard withAgent > 0 else {
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "\(images.count) local image(s), none carry a RunnerVM guest agent; build one "
          + "with `runnerctl image build` (images imported from tart are inspection-only)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(withAgent)/\(images.count) local image(s) carry a guest agent"
    )
  }
}
