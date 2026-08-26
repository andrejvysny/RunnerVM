import Foundation
import Logging
import RunnerLogging

/// Where the free-space/floor comparison landed (spec §17 "absolute free-space floor").
public enum DiskPressureState: String, Sendable, Codable, Hashable, CaseIterable {
  case ok
  case warning
  case critical
}

/// One measurement: raw free bytes, the configured floor, and the state they classify to.
public struct DiskPressureReport: Sendable, Hashable {
  public var freeBytes: UInt64
  public var floorBytes: UInt64
  public var state: DiskPressureState

  public init(freeBytes: UInt64, floorBytes: UInt64, state: DiskPressureState) {
    self.freeBytes = freeBytes
    self.floorBytes = floorBytes
    self.state = state
  }
}

/// Tracks host free space against the configured floor (spec §17).
///
/// A stateful actor rather than a pure function: it remembers the state it last reported so
/// `refresh` logs only on a transition, not once per poll -- a daemon sitting in `critical` would
/// otherwise fill the log with an identical line on every reconcile tick.
public actor DiskPressureMonitor {
  private let freeSpace: @Sendable () -> UInt64
  private let logger: Logger
  private var last: DiskPressureState = .ok

  public init(
    freeSpace: @escaping @Sendable () -> UInt64, logger: Logger = Logger(component: .daemon)
  ) {
    self.freeSpace = freeSpace
    self.logger = logger
  }

  /// `warning` starts 10% above the floor, so an operator gets a heads-up before admission
  /// actually stops; `critical` is at or below the floor itself (spec §17).
  public static func classify(freeBytes: UInt64, floorBytes: UInt64) -> DiskPressureState {
    guard freeBytes > floorBytes else { return .critical }
    let cushion = floorBytes + floorBytes / 10
    return freeBytes > cushion ? .ok : .warning
  }

  @discardableResult
  public func refresh(floorBytes: UInt64) -> DiskPressureReport {
    let free = freeSpace()
    let state = Self.classify(freeBytes: free, floorBytes: floorBytes)
    if state != last {
      logger.warning(
        "disk pressure changed",
        metadata: [
          "from": .string(last.rawValue), "to": .string(state.rawValue),
          "free_bytes": .stringConvertible(free), "floor_bytes": .stringConvertible(floorBytes),
        ])
      last = state
    }
    return DiskPressureReport(freeBytes: free, floorBytes: floorBytes, state: state)
  }
}
