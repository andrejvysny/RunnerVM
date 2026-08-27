import Foundation

/// Typed identifier wrapper. Prevents mixing InstanceID with RunnerSessionID etc. (spec §83).
public protocol TypedID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
  where RawValue == String {
  init(rawValue: String)
}

extension TypedID {
  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static func generate() -> Self {
    Self(rawValue: UUID().uuidString.lowercased())
  }
}

public struct InstanceID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct RunnerSessionID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct RunnerProfileID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct GitHubScopeID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct OperationID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct HostID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

/// sha256:<hex> content digest of an image manifest.
public struct ImageDigest: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

/// One in-daemon image build (Phase 4/5 image builder). Distinct from `ImageDigest`: a build is the
/// process, not its output -- a successful build eventually produces one.
public struct ImageBuildID: TypedID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public enum GuestOS: String, Codable, Sendable {
  case linux
  case macos
}
