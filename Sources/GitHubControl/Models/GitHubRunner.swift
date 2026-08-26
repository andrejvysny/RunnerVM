import Foundation

/// One label attached to a registered runner. GitHub returns objects, not strings.
public struct GitHubRunnerLabel: Decodable, Sendable, Hashable {
  public let id: Int64?
  public let name: String
  /// `read-only` for the labels GitHub adds itself, `custom` for ours.
  public let type: String?

  public init(id: Int64? = nil, name: String, type: String? = nil) {
    self.id = id
    self.name = name
    self.type = type
  }
}

/// A self-hosted runner as GitHub reports it.
public struct GitHubRunner: Decodable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let os: String
  /// `online` or `offline`. Kept as text because GitHub may add values and an unknown one must
  /// not fail decoding of an otherwise usable response.
  public let status: String
  public let busy: Bool
  public let labels: [GitHubRunnerLabel]

  public init(
    id: Int64, name: String, os: String = "", status: String = "offline", busy: Bool = false,
    labels: [GitHubRunnerLabel] = []
  ) {
    self.id = id
    self.name = name
    self.os = os
    self.status = status
    self.busy = busy
    self.labels = labels
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    os = try container.decodeIfPresent(String.self, forKey: .os) ?? ""
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "offline"
    busy = try container.decodeIfPresent(Bool.self, forKey: .busy) ?? false
    labels = try container.decodeIfPresent([GitHubRunnerLabel].self, forKey: .labels) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, os, status, busy, labels
  }

  public var labelNames: [String] {
    labels.map(\.name)
  }

  public var isOnline: Bool {
    status.caseInsensitiveCompare("online") == .orderedSame
  }

  public var state: GitHubRunnerState {
    isOnline ? .online(busy: busy) : .offline(busy: busy)
  }
}

/// What the orchestrator asks about a runner it created. `absent` covers both "GitHub 404'd" and
/// "we already removed it", which is the same decision for cleanup.
public enum GitHubRunnerState: Sendable, Hashable {
  case online(busy: Bool)
  case offline(busy: Bool)
  case absent

  public var exists: Bool {
    self != .absent
  }

  public var busy: Bool {
    switch self {
    case let .online(busy), let .offline(busy): busy
    case .absent: false
    }
  }
}

/// An organization runner group (spec §134). Only the fields RunnerVM resolves against.
public struct RunnerGroup: Decodable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let visibility: String?
  public let allowsPublicRepositories: Bool?

  public init(
    id: Int64, name: String, visibility: String? = nil, allowsPublicRepositories: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.visibility = visibility
    self.allowsPublicRepositories = allowsPublicRepositories
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, visibility
    case allowsPublicRepositories = "allows_public_repositories"
  }
}

/// Answer to the spec §77 public-repository guard.
public struct RepositoryVisibility: Decodable, Sendable, Hashable {
  public let isPrivate: Bool
  /// `public`, `private` or `internal`. Absent on very old GitHub Enterprise responses.
  public let visibility: String

  public init(isPrivate: Bool, visibility: String) {
    self.isPrivate = isPrivate
    self.visibility = visibility
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
    visibility =
      try container.decodeIfPresent(String.self, forKey: .visibility)
        ?? (isPrivate ? "private" : "public")
  }

  public var isPublic: Bool {
    !isPrivate && visibility.caseInsensitiveCompare("public") == .orderedSame
  }

  private enum CodingKeys: String, CodingKey {
    case isPrivate = "private"
    case visibility
  }
}
