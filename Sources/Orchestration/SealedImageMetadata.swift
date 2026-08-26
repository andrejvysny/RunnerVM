import Foundation
import ImageStore
import Logging
import RunnerCore
import RunnerLogging

/// `runnerctl image import` used to throw away everything `scripts/build-ubuntu-image.sh` had
/// sealed: `runnerVersion`, `guestAgentVersion`, `capabilities` and the whole provenance block were
/// re-synthesised from the disk size and `--os` alone. This is the other half -- reading the sealed
/// `metadata.json` back in, so an imported image still knows what it is made of.
extension ImageManager {
  /// The file `scripts/build-ubuntu-image.sh` writes next to `disk.img`.
  static let sealedMetadataFile = "metadata.json"

  /// Adopts a sealed `metadata.json` when there is a usable one, and synthesises otherwise.
  ///
  /// `metadataPath` is an explicit `--metadata` override and is therefore fatal when unusable; the
  /// implicit sibling of `disk` only warns, because most disks have no sealed metadata at all.
  func resolveImportMetadata(
    disk: URL, size: UInt64, os: GuestOS, hardwareModel: String?, metadataPath: URL?
  ) throws -> ImageMetadata {
    let sibling = disk.deletingLastPathComponent().appending(path: Self.sealedMetadataFile)
    let source = metadataPath ?? sibling
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
      if let metadataPath {
        throw ImageError.notFound(reference: metadataPath.path(percentEncoded: false))
      }
      logger.info("image metadata synthesised (no sealed metadata.json beside the disk)")
      return synthesise(size: size, os: os, hardwareModel: hardwareModel)
    }
    do {
      let sealed = try Self.decodeSealed(at: source, expecting: os)
      logger.info(
        "image metadata adopted from sealed metadata.json",
        metadata: [
          "path": .string(source.path(percentEncoded: false)),
          "runner_version": .string(sealed.runnerVersion ?? "-"),
          "provenance": .string(sealed.provenance == nil ? "absent" : "present"),
        ])
      return Self.reconcile(sealed, size: size, hardwareModel: hardwareModel)
    } catch {
      if metadataPath != nil { throw error }
      logger.warning(
        "sealed metadata.json ignored; synthesising instead",
        metadata: [
          "path": .string(source.path(percentEncoded: false)),
          "reason": .string("\(error)"),
        ])
      return synthesise(size: size, os: os, hardwareModel: hardwareModel)
    }
  }

  /// A sealed file is only adopted whole: mixing a linux `metadata.json` into a `--os macos` import
  /// would produce metadata that describes neither image.
  private static func decodeSealed(at url: URL, expecting os: GuestOS) throws -> ImageMetadata {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sealed: ImageMetadata
    do {
      sealed = try decoder.decode(ImageMetadata.self, from: try Data(contentsOf: url))
    } catch {
      throw ImageError.metadataInvalid(reason: "cannot decode \(url.lastPathComponent): \(error)")
    }
    guard sealed.schemaVersion == ImageMetadata.currentSchemaVersion else {
      throw ImageError.manifestUnsupported(
        reason: "sealed metadata schemaVersion \(sealed.schemaVersion)")
    }
    guard sealed.os == os else {
      // "image is <actual> but the profile declares <expected>": the sealed file is what the
      // image really is, the requested `--os` is what the caller declared.
      throw ImageError.incompatibleGuestOS(expected: os, actual: sealed.os)
    }
    return sealed
  }

  /// The disk on disk wins over what the file claims: `ImageStore.importLocal` validates
  /// `virtualDiskSizeBytes` against the real file and would reject a stale figure.
  private static func reconcile(
    _ sealed: ImageMetadata, size: UInt64, hardwareModel: String?
  ) -> ImageMetadata {
    var metadata = sealed
    metadata.virtualDiskSizeBytes = size
    if metadata.macos == nil, let hardwareModel {
      metadata.macos = ImageMetadata.MacOSPlatform(hardwareModel: hardwareModel)
    }
    return metadata
  }

  private func synthesise(size: UInt64, os: GuestOS, hardwareModel: String?) -> ImageMetadata {
    ImageMetadata(
      os: os,
      architecture: architecture,
      virtualDiskSizeBytes: size,
      // The injected clock, not `Date()`: `createdAt` feeds the content digest through
      // `metadata.json`, so a test that imports the same bytes twice must be able to pin it.
      createdAt: now(),
      boot: ImageMetadata.Boot(type: os == .macos ? .macos : .efi),
      macos: hardwareModel.map { ImageMetadata.MacOSPlatform(hardwareModel: $0) })
  }
}
