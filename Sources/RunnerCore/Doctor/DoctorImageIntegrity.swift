import Foundation

/// Pure comparison logic behind `runnerctl doctor`'s `image_store_integrity` check (spec WP9):
/// given what a manifest recorded and what is actually on disk, decide whether they still agree.
/// The actual `stat`/sha256 calls stay in `runnerctl` (host I/O via `ImageStore`); this only
/// grades the numbers.
public enum DoctorImageIntegrity {
  /// One layer's recorded-vs-actual comparison. `actualBytes` is `nil` when the blob file itself
  /// is missing (a stronger problem than a size mismatch, reported distinctly).
  public struct LayerCheck: Sendable, Equatable {
    public var digest: String
    public var recordedBytes: UInt64
    public var actualBytes: UInt64?

    public init(digest: String, recordedBytes: UInt64, actualBytes: UInt64?) {
      self.digest = digest
      self.recordedBytes = recordedBytes
      self.actualBytes = actualBytes
    }

    /// `nil` when the layer is consistent; otherwise a one-line reason, matching the rest of
    /// doctor's detail-string convention.
    public var problem: String? {
      guard let actualBytes else {
        return "blob missing for \(digest)"
      }
      guard actualBytes == recordedBytes else {
        return "\(digest) size mismatch: manifest says \(recordedBytes), file is \(actualBytes)"
      }
      return nil
    }
  }

  /// The first inconsistent layer, across every manifest checked -- doctor reports this one
  /// rather than every mismatch, matching the one-line-detail convention the other checks use.
  public static func firstMismatch<Key>(
    _ checks: [(key: Key, layer: LayerCheck)]
  ) -> (key: Key, layer: LayerCheck)? {
    checks.first { $0.layer.problem != nil }
  }
}
