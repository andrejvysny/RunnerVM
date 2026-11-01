import Foundation

// `fleet.*` (`Proto/fleet.md`). Field names are what `GuestAgent/internal/fleet/client.go` sends
// and decodes; integer fields are int64 on the wire and timestamps are RFC 3339 strings, the same
// format `InstanceInfoDTO.pinnedUntil` uses.

/// Bounds on `leaseMs` for `fleet.create` and `fleet.renew`. The floor keeps a lease longer than a
/// boot; the ceiling bounds how long a crashed gitlab-runner can hold host capacity.
public enum FleetLease {
  public static let minimumMs: Int64 = 60_000
  public static let maximumMs: Int64 = 24 * 60 * 60 * 1_000
  public static let range: ClosedRange<Int64> = minimumMs...maximumMs
}

public struct FleetInfoRequest: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}

public struct FleetInfoResponse: Codable, Sendable, Hashable {
  public var profile: String
  /// `linux` or `macos`.
  public var guestOS: String
  public var arch: String
  public var sshUser: String
  public var maxInstances: Int64

  public init(profile: String, guestOS: String, arch: String, sshUser: String, maxInstances: Int64) {
    self.profile = profile
    self.guestOS = guestOS
    self.arch = arch
    self.sshUser = sshUser
    self.maxInstances = maxInstances
  }
}

public struct FleetListRequest: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}

public struct FleetInstanceDTO: Codable, Sendable, Hashable {
  public var id: String
  /// `creating`, `running`, `deleting` or `deleted`.
  public var state: String
  public var leaseUntil: String?

  public init(id: String, state: String, leaseUntil: String? = nil) {
    self.id = id
    self.state = state
    self.leaseUntil = leaseUntil
  }
}

public struct FleetListResponse: Codable, Sendable, Hashable {
  public var instances: [FleetInstanceDTO]

  public init(instances: [FleetInstanceDTO]) { self.instances = instances }
}

public struct FleetCreateRequest: Codable, Sendable, Hashable {
  public var profile: String
  public var leaseMs: Int64

  public init(profile: String, leaseMs: Int64) {
    self.profile = profile
    self.leaseMs = leaseMs
  }
}

public struct FleetCreateResponse: Codable, Sendable, Hashable {
  public var id: String
  public var leaseUntil: String

  public init(id: String, leaseUntil: String) {
    self.id = id
    self.leaseUntil = leaseUntil
  }
}

public struct FleetDeleteRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}

public struct FleetDeleteResponse: Codable, Sendable, Hashable {
  public var id: String
  public var accepted: Bool

  public init(id: String, accepted: Bool) {
    self.id = id
    self.accepted = accepted
  }
}

public struct FleetRenewRequest: Codable, Sendable, Hashable {
  public var ids: [String]
  public var leaseMs: Int64

  public init(ids: [String], leaseMs: Int64) {
    self.ids = ids
    self.leaseMs = leaseMs
  }
}

public struct FleetRenewResponse: Codable, Sendable, Hashable {
  public var renewed: [String]

  public init(renewed: [String]) { self.renewed = renewed }
}

public struct FleetConnectRequest: Codable, Sendable, Hashable {
  public var id: String
  public var publicKey: String

  public init(id: String, publicKey: String) {
    self.id = id
    self.publicKey = publicKey
  }
}

public struct FleetConnectResponse: Codable, Sendable, Hashable {
  public var id: String
  public var address: String
  public var port: Int64
  public var user: String
  public var guestOS: String
  public var arch: String

  public init(id: String, address: String, port: Int64, user: String, guestOS: String, arch: String) {
    self.id = id
    self.address = address
    self.port = port
    self.user = user
    self.guestOS = guestOS
    self.arch = arch
  }
}
