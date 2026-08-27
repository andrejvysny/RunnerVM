import Foundation
import RunnerCore

/// Clones a disk (and optional nvram) into a staging directory, writes `spec.json` and an empty
/// `worker.lock` -- the file-level mechanics shared by `InstanceStore.materialize` and (Phase 5)
/// the image builder's `BuildStore.materialize`, so both produce byte-identical directory layouts.
public enum VMDirectoryStaging {
  /// Where a cloned disk or nvram store comes from: an immutable image-store blob (mode 0444,
  /// shared across every clone of that image), or an arbitrary file already on this host.
  public enum DiskSource: Sendable {
    case blob(URL)
    case file(URL)

    var url: URL {
      switch self {
      case let .blob(url), let .file(url): url
      }
    }
  }

  /// - Parameters:
  ///   - staging: Directory the clone, spec and lock file are written into. Must already exist.
  ///   - disk: Source to clone `disk.img` from.
  ///   - nvram: Source to clone `nvram.bin` from, or `nil` to omit it entirely.
  ///   - diskBytes: Requested disk size. Truncating a sparse raw disk upward is free; shrinking is
  ///     never attempted here.
  ///   - imageBytes: The source disk's own logical size, so `diskBytes > imageBytes` decides
  ///     whether to truncate up.
  ///   - spec: Encoded to `spec.json`.
  ///   - allowFullCopy: Falls back to a full copy when `staging` is not on a clone-capable volume.
  @discardableResult
  public static func stage(
    into staging: URL, disk: DiskSource, nvram: DiskSource?, diskBytes: UInt64, imageBytes: UInt64,
    spec: some Encodable & Sendable, allowFullCopy: Bool
  ) throws -> CloneMethod {
    let diskURL = VMInstanceLayout.diskPath(in: staging)
    let method = try APFSClone.cloneOrCopy(from: disk.url, to: diskURL, allowFullCopy: allowFullCopy)
    // `clonefile(2)` copies the source mode, and image blobs are 0444; the guest needs to write.
    try FileSystem.setMode(0o600, at: diskURL)
    if diskBytes > imageBytes {
      try FileSystem.truncate(diskURL, to: diskBytes)
    }
    if let nvram {
      let nvramURL = VMInstanceLayout.nvramPath(in: staging)
      _ = try APFSClone.cloneOrCopy(from: nvram.url, to: nvramURL, allowFullCopy: allowFullCopy)
      try FileSystem.setMode(0o600, at: nvramURL)
    }
    try FileSystem.write(
      try CanonicalJSON.encode(spec), to: staging.appending(path: VMInstanceLayout.specName), mode: 0o600
    )
    try FileSystem.createEmptyFile(
      at: VMInstanceLayout.workerLockPath(in: staging), mode: 0o600
    )
    return method
  }
}
