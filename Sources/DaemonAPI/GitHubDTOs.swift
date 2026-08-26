import Foundation

// MARK: - auth.*

/// `auth.status` response (spec §12, §148). Never carries the token itself — only where it came
/// from and whether GitHub accepted it.
public struct AuthStatus: Codable, Sendable, Hashable {
  /// `unconfigured`, `healthy`, `invalid`, `degraded` or `unknown` (never probed yet).
  public var state: String
  /// `GitHubAuthConfig.Provider` raw value.
  public var provider: String
  /// `GitHubAuthConfig.Source` raw value.
  public var source: String
  /// Human description of where the credential is read from, e.g. `keychain com.runnervm.github/default`.
  public var location: String
  /// GitHub login behind a PAT; `nil` for a GitHub App installation token.
  public var login: String?
  /// `CODE: message` when the probe failed.
  public var problem: String?
  /// Operator-facing next step when `state` is not `healthy`.
  public var hint: String?
  public var checkedAt: String?

  public init(
    state: String, provider: String, source: String, location: String, login: String? = nil,
    problem: String? = nil, hint: String? = nil, checkedAt: String? = nil
  ) {
    self.state = state
    self.provider = provider
    self.source = source
    self.location = location
    self.login = login
    self.problem = problem
    self.hint = hint
    self.checkedAt = checkedAt
  }
}

/// The token travels over the peer-checked Unix socket only; it is never written to the applied
/// YAML document and never logged (spec §12, §129).
public struct AuthLoginRequest: Codable, Sendable, Hashable {
  public var token: String

  public init(token: String) { self.token = token }
}

public struct AuthLoginResponse: Codable, Sendable, Hashable {
  /// Where the token landed, e.g. `file /…/state/github-token` or `keychain …`.
  public var location: String
  public var status: AuthStatus

  public init(location: String, status: AuthStatus) {
    self.location = location
    self.status = status
  }
}

public struct AuthLogoutResponse: Codable, Sendable, Hashable {
  public var location: String
  /// `false` when there was nothing stored — logout is idempotent.
  public var removed: Bool

  public init(location: String, removed: Bool) {
    self.location = location
    self.removed = removed
  }
}

// MARK: - github.test

/// One `GitHubScopeHealth.Problem`, flattened for the wire.
public struct ScopeProblemDTO: Codable, Sendable, Hashable {
  public var code: String
  public var errorClass: String?
  public var detail: String

  public init(code: String, errorClass: String?, detail: String) {
    self.code = code
    self.errorClass = errorClass
    self.detail = detail
  }
}

public struct ScopeHealthDTO: Codable, Sendable, Hashable {
  public var name: String
  public var slug: String
  public var kind: String
  /// `healthy`, `degraded`, `unhealthy` or `unknown`.
  public var status: String
  public var runnerGroup: String?
  public var runnerGroupId: Int64?
  public var visibility: String?
  public var isPublicRepository: Bool?
  public var runnerCount: Int?
  public var schedulable: Bool
  public var problems: [ScopeProblemDTO]

  public init(
    name: String, slug: String, kind: String, status: String, runnerGroup: String? = nil,
    runnerGroupId: Int64? = nil, visibility: String? = nil, isPublicRepository: Bool? = nil,
    runnerCount: Int? = nil, schedulable: Bool, problems: [ScopeProblemDTO] = []
  ) {
    self.name = name
    self.slug = slug
    self.kind = kind
    self.status = status
    self.runnerGroup = runnerGroup
    self.runnerGroupId = runnerGroupId
    self.visibility = visibility
    self.isPublicRepository = isPublicRepository
    self.runnerCount = runnerCount
    self.schedulable = schedulable
    self.problems = problems
  }
}

/// `github.test` — one live probe of the credential plus every configured scope (spec §148).
public struct GitHubTestResponse: Codable, Sendable, Hashable {
  public var auth: AuthStatus
  public var scopes: [ScopeHealthDTO]

  public init(auth: AuthStatus, scopes: [ScopeHealthDTO]) {
    self.auth = auth
    self.scopes = scopes
  }
}

// MARK: - runner.*

/// One `runner_sessions` row. The JIT config it delivered is deliberately absent: it is never
/// persisted, so there is nothing to report (spec §36, §128).
public struct RunnerSessionDTO: Codable, Sendable, Hashable {
  public var id: String
  public var instanceId: String
  public var profile: String
  public var jitSource: String
  public var state: String
  public var githubRunnerId: Int64?
  public var githubRunnerName: String?
  public var result: String?
  public var failureCode: String?
  public var createdAt: String
  public var jitIssuedAt: String?
  public var jitDeliveredAt: String?
  public var runnerStartedAt: String?
  public var runnerOnlineAt: String?
  public var jobStartedAt: String?
  public var jobFinishedAt: String?
  public var updatedAt: String
  /// True once the session reached a state it can never leave.
  public var terminal: Bool

  public init(
    id: String, instanceId: String, profile: String, jitSource: String, state: String,
    githubRunnerId: Int64? = nil, githubRunnerName: String? = nil, result: String? = nil,
    failureCode: String? = nil, createdAt: String, jitIssuedAt: String? = nil,
    jitDeliveredAt: String? = nil, runnerStartedAt: String? = nil, runnerOnlineAt: String? = nil,
    jobStartedAt: String? = nil, jobFinishedAt: String? = nil, updatedAt: String, terminal: Bool
  ) {
    self.id = id
    self.instanceId = instanceId
    self.profile = profile
    self.jitSource = jitSource
    self.state = state
    self.githubRunnerId = githubRunnerId
    self.githubRunnerName = githubRunnerName
    self.result = result
    self.failureCode = failureCode
    self.createdAt = createdAt
    self.jitIssuedAt = jitIssuedAt
    self.jitDeliveredAt = jitDeliveredAt
    self.runnerStartedAt = runnerStartedAt
    self.runnerOnlineAt = runnerOnlineAt
    self.jobStartedAt = jobStartedAt
    self.jobFinishedAt = jobFinishedAt
    self.updatedAt = updatedAt
    self.terminal = terminal
  }
}

public struct RunnerListResponse: Codable, Sendable, Hashable {
  public var sessions: [RunnerSessionDTO]

  public init(sessions: [RunnerSessionDTO]) { self.sessions = sessions }
}

public struct RunnerGetRequest: Codable, Sendable, Hashable {
  public var sessionId: String

  public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - debug.runJit

public struct DebugRunJITRequest: Codable, Sendable, Hashable {
  public var profile: String

  public init(profile: String) { self.profile = profile }
}

public struct DebugRunJITResponse: Codable, Sendable, Hashable {
  public var sessionId: String
  public var instanceId: String
  /// True when this call created the instance rather than reusing an idle one.
  public var createdInstance: Bool

  public init(sessionId: String, instanceId: String, createdInstance: Bool) {
    self.sessionId = sessionId
    self.instanceId = instanceId
    self.createdInstance = createdInstance
  }
}
