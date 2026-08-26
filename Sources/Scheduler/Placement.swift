import Foundation
import RunnerCore

/// Placement seam for a future multi-host controller (spec §85). V1 has exactly one host; the
/// protocol exists so `host_id` is never assumed constant in the schema.
public protocol InstancePlacementStrategy: Sendable {
  func chooseHost(for request: ResourceRequest) throws -> HostID
}

public struct SingleHostPlacementStrategy: InstancePlacementStrategy, Sendable, Hashable {
  public let localHost: HostID

  public init(localHost: HostID) {
    self.localHost = localHost
  }

  public func chooseHost(for request: ResourceRequest) throws -> HostID {
    localHost
  }
}
