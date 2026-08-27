import Foundation
import RunnerCore

/// The EFI variable store (Linux) or auxiliary storage (macOS): small, opaque and stored raw.
///
/// No compression and no chunking — the file is a handful of megabytes at most, and keeping it
/// byte-identical means `ImageStore` re-imports it to the same blob digest.
public enum NVRAMLayer {
  /// Refuses anything large enough to suggest the wrong file was passed.
  public static let maximumBytes = 128 * 1024 * 1024

  public static func push(
    fileURL: URL, os: GuestOS, repository: String, registry: RegistryClient
  ) async throws -> OCIDescriptor {
    let size = try DiskLayerizer.fileSize(of: fileURL)
    guard size <= UInt64(maximumBytes) else {
      throw RegistryError.invalidResponse(
        operation: "push NVRAM", reason: "\(size) bytes exceeds the \(maximumBytes)-byte limit"
      )
    }
    let data = try Data(contentsOf: fileURL)
    let digest = ContentDigest.hash(data)
    if try await !registry.blobExists(digest, repository: repository) {
      _ = try await registry.pushBlob(data, digest: digest, repository: repository)
    }
    return OCIDescriptor(
      mediaType: RunnerVMMediaType.nvram(for: os), digest: digest, size: Int64(data.count)
    )
  }

  public static func pull(
    descriptor: OCIDescriptor, to fileURL: URL, repository: String, registry: RegistryClient
  ) async throws {
    guard descriptor.size >= 0 else {
      throw RegistryError.unsupportedManifest(
        reason: "NVRAM layer declares a negative size \(descriptor.size)"
      )
    }
    guard descriptor.size <= Int64(maximumBytes) else {
      throw RegistryError.unsupportedManifest(
        reason: "NVRAM layer of \(descriptor.size) bytes exceeds the \(maximumBytes)-byte limit"
      )
    }
    var buffer = Data()
    buffer.reserveCapacity(Int(descriptor.size))
    try await registry.pullBlob(
      descriptor.digest, repository: repository, expectedSize: descriptor.size
    ) { data in
      buffer.append(data)
    }
    try buffer.write(to: fileURL, options: .atomic)
  }
}
