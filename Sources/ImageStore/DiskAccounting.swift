import Foundation
import RunnerCore

/// Disk side of the capacity reservation taken at `planned`, before any expensive clone or boot work
/// begins (spec §121).
public enum DiskAccounting {
  /// What the scheduler must commit for one instance.
  ///
  /// v1 is deliberately worst-case: an APFS clone starts at nearly zero allocation, but a job may
  /// dirty every block of its disk and nothing shrinks a raw disk back afterwards. Reserving the
  /// profile's full size is the only figure that cannot oversubscribe the host mid-job; a
  /// growth-aware estimate would need per-profile history that does not exist yet.
  public static func estimatedAdditionalAllocation(for diskBytes: UInt64, image: ImageInfo) -> UInt64 {
    max(diskBytes, image.virtualBytes)
  }

  /// Free space minus the host's configured floor, compared against what a new instance needs.
  /// `reserveBytes` is the floor the host must keep for macOS itself and for logs.
  public static func hostFreeSpaceCheck(paths: RunnerPaths, reserveBytes: UInt64, needed: UInt64) throws {
    let free = APFSClone.freeSpace(at: paths.instancesDir)
    let available = free > reserveBytes ? free - reserveBytes : 0
    guard needed <= available else {
      throw ImageError.insufficientDiskSpace(requiredBytes: needed, availableBytes: available)
    }
  }
}
