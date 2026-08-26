import Foundation
import Synchronization

/// Byte counter for a push or pull, safe to share across the layerizer's task group.
public final class TransferProgress: Sendable {
  public let totalBytes: UInt64
  private let completed = Mutex<UInt64>(0)
  private let onUpdate: (@Sendable (UInt64, UInt64) -> Void)?

  public init(
    totalBytes: UInt64,
    onUpdate: (@Sendable (_ completed: UInt64, _ total: UInt64) -> Void)? = nil
  ) {
    self.totalBytes = totalBytes
    self.onUpdate = onUpdate
  }

  public var completedBytes: UInt64 {
    completed.withLock { $0 }
  }

  public func advance(by bytes: UInt64) {
    let now = completed.withLock { value -> UInt64 in
      value += bytes
      return value
    }
    onUpdate?(now, totalBytes)
  }
}
