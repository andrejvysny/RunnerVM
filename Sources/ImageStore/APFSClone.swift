import Darwin
import Foundation
import RunnerCore

/// How an instance disk was produced. Surfaced as the `instance_clone_method` metric (spec §23).
public enum CloneMethod: String, Sendable, Codable, CaseIterable {
  case apfsCoW = "apfs_cow"
  case fullCopy = "full_copy"
}

/// APFS copy-on-write primitives. A clone shares blocks with the source until something writes, so
/// an 80 GiB image becomes an instance in milliseconds and costs only what the job dirties (spec §20).
public enum APFSClone {
  /// `clonefile(2)`. Throws `ImageError.cloneUnsupported` when the destination volume cannot clone
  /// (different volume, or not APFS) — the caller decides whether a full copy is acceptable (§23).
  public static func clone(from source: URL, to destination: URL) throws -> CloneMethod {
    let src = source.path(percentEncoded: false)
    let dst = destination.path(percentEncoded: false)
    guard clonefile(src, dst, 0) == 0 else {
      let code = errno
      if code == ENOTSUP || code == EXDEV || code == EOPNOTSUPP || code == ENOSYS {
        throw ImageError.cloneUnsupported(path: dst)
      }
      throw ImageError.cloneFailed(reason: "clonefile \(src) -> \(dst): \(String(cString: strerror(code)))")
    }
    return .apfsCoW
  }

  /// Clone, falling back to a full copy only when the caller has explicitly allowed it (spec §23).
  public static func cloneOrCopy(
    from source: URL, to destination: URL, allowFullCopy: Bool
  ) throws -> CloneMethod {
    do {
      return try clone(from: source, to: destination)
    } catch let error as ImageError {
      guard case .cloneUnsupported = error, allowFullCopy else { throw error }
      try FileManager.default.copyItem(at: source, to: destination)
      return .fullCopy
    }
  }

  public static func volumeSupportsClone(at url: URL) -> Bool {
    let values = try? existingAncestor(of: url).resourceValues(forKeys: [.volumeSupportsFileCloningKey])
    return values?.volumeSupportsFileCloning ?? false
  }

  /// Space the volume will really hand over, i.e. after purgeable caches are reclaimed. Using the
  /// "important usage" key rather than raw free space avoids refusing to boot a VM on a Mac whose
  /// free space is mostly reclaimable.
  ///
  /// That key is computed by a per-login-session service, so it answers 0 in every session that
  /// has none: a LaunchDaemon, or a daemon started over SSH on a Mac with nobody logged in --
  /// exactly the unattended host this is written for. Reading it as "no space" put the daemon in
  /// permanent `critical` disk pressure and advertised `capacity=0`, so no VM was ever scheduled
  /// (seen live on macOS 26.5.2: `importantUsage` 0 against 70 GiB of real free space). Fall back
  /// to the plain available-capacity figure there; it undercounts purgeable space, which is the
  /// safe direction for an admission check.
  public static func freeSpace(at url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ]
    guard let values = try? existingAncestor(of: url).resourceValues(forKeys: keys) else {
      return 0
    }
    if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
      return UInt64(important)
    }
    if let available = values.volumeAvailableCapacity, available > 0 {
      return UInt64(available)
    }
    return 0
  }

  /// Volume queries need a path that exists; the store's directories are created lazily.
  static func existingAncestor(of url: URL) -> URL {
    var candidate = url.standardizedFileURL
    while !FileSystem.exists(candidate), candidate.pathComponents.count > 1 {
      candidate = candidate.deletingLastPathComponent()
    }
    return candidate
  }
}
