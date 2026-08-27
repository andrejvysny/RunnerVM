import Foundation

public struct ProfileSummary: Codable, Sendable, Hashable {
  public var name: String
  public var scope: String
  public var image: String
  public var guestOS: String
  public var lifecycle: String
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var minIdle: Int
  public var maxIdle: Int
  public var maxInstances: Int?
  public var sshEnabled: Bool
  public var enabled: Bool
  public var updatedAt: String

  public init(
    name: String, scope: String, image: String, guestOS: String, lifecycle: String, cpuCount: Int,
    memoryBytes: UInt64, diskBytes: UInt64, minIdle: Int, maxIdle: Int, maxInstances: Int?,
    sshEnabled: Bool, enabled: Bool, updatedAt: String
  ) {
    self.name = name
    self.scope = scope
    self.image = image
    self.guestOS = guestOS
    self.lifecycle = lifecycle
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.minIdle = minIdle
    self.maxIdle = maxIdle
    self.maxInstances = maxInstances
    self.sshEnabled = sshEnabled
    self.enabled = enabled
    self.updatedAt = updatedAt
  }
}

public struct ProfileListResponse: Codable, Sendable, Hashable {
  public var profiles: [ProfileSummary]

  public init(profiles: [ProfileSummary]) { self.profiles = profiles }
}

public struct ProfileGetRequest: Codable, Sendable, Hashable {
  public var name: String

  public init(name: String) { self.name = name }
}

public struct ScopeSummary: Codable, Sendable, Hashable {
  public var name: String
  public var kind: String
  public var owner: String
  public var repository: String?
  public var runnerGroup: String?
  public var enabled: Bool
  public var health: String
  public var updatedAt: String

  public init(
    name: String, kind: String, owner: String, repository: String? = nil,
    runnerGroup: String? = nil, enabled: Bool, health: String, updatedAt: String
  ) {
    self.name = name
    self.kind = kind
    self.owner = owner
    self.repository = repository
    self.runnerGroup = runnerGroup
    self.enabled = enabled
    self.health = health
    self.updatedAt = updatedAt
  }

  /// `acme` or `acme/project-a`, matching `GitHubScopeConfig.slug`.
  public var slug: String {
    guard let repository, !repository.isEmpty else { return owner }
    return "\(owner)/\(repository)"
  }
}

public struct ScopeListResponse: Codable, Sendable, Hashable {
  public var scopes: [ScopeSummary]

  public init(scopes: [ScopeSummary]) { self.scopes = scopes }
}

public struct ScopeGetRequest: Codable, Sendable, Hashable {
  public var name: String

  public init(name: String) { self.name = name }
}

public struct OperationInfo: Codable, Sendable, Hashable {
  public var id: String
  public var kind: String
  public var resourceType: String
  public var resourceId: String
  public var state: String
  public var startedAt: String
  public var finishedAt: String?
  public var errorCode: String?
  public var errorMessage: String?
  /// Key/value result a finished operation reports, e.g. `pushedReference` for `push-image` (the
  /// immutable `@sha256:` form the registry assigned). Absent on daemons predating the field.
  public var result: [String: String]?

  public init(
    id: String, kind: String, resourceType: String, resourceId: String, state: String,
    startedAt: String, finishedAt: String? = nil, errorCode: String? = nil,
    errorMessage: String? = nil, result: [String: String]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.resourceType = resourceType
    self.resourceId = resourceId
    self.state = state
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.errorCode = errorCode
    self.errorMessage = errorMessage
    self.result = result
  }
}

public struct OperationListResponse: Codable, Sendable, Hashable {
  public var operations: [OperationInfo]

  public init(operations: [OperationInfo]) { self.operations = operations }
}

public struct OperationGetRequest: Codable, Sendable, Hashable {
  public var id: String

  public init(id: String) { self.id = id }
}
