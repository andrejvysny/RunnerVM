import Foundation
import RunnerCore

/// The single place where GitHub's organization-vs-repository URL differences are allowed to
/// live (spec §11: "Do not spread scope-specific URL logic through the scheduler").
public enum GitHubScope: Sendable, Hashable, CustomStringConvertible {
  case organization(owner: String, runnerGroupID: Int64?)
  case repository(owner: String, repository: String)

  /// GitHub requires an explicit `runner_group_id` even for a repository, which always has
  /// exactly one group: the default, id 1.
  public static let defaultRunnerGroupID: Int64 = 1

  /// - Parameter runnerGroupID: resolved id for an organization scope (spec §134). Repository
  ///   scopes ignore it.
  public init(config: GitHubScopeConfig, runnerGroupID: Int64? = nil) throws {
    switch config.kind {
    case .organization:
      self = .organization(owner: config.owner, runnerGroupID: runnerGroupID)
    case .repository:
      guard let repository = config.repository, !repository.isEmpty else {
        throw GitHubControlError.permanentConfiguration(
          reason: "scope '\(config.name)' has type repository but no repository name"
        )
      }
      self = .repository(owner: config.owner, repository: repository)
    }
  }

  public var kind: GitHubScopeKind {
    switch self {
    case .organization: .organization
    case .repository: .repository
    }
  }

  public var owner: String {
    switch self {
    case let .organization(owner, _): owner
    case let .repository(owner, _): owner
    }
  }

  /// `acme` or `acme/project-a` — the form used in log messages and error text.
  public var slug: String {
    switch self {
    case let .organization(owner, _): owner
    case let .repository(owner, repository): "\(owner)/\(repository)"
    }
  }

  public var description: String {
    "\(kind.rawValue):\(slug)"
  }

  /// Group the runner registers into. Organization scopes fall back to the default group when
  /// the configuration named none.
  public var runnerGroupID: Int64 {
    switch self {
    case let .organization(_, id): id ?? Self.defaultRunnerGroupID
    case .repository: Self.defaultRunnerGroupID
    }
  }

  // MARK: - Paths

  var actionsPath: String {
    switch self {
    case let .organization(owner, _):
      "/orgs/\(Self.escape(owner))/actions"
    case let .repository(owner, repository):
      "/repos/\(Self.escape(owner))/\(Self.escape(repository))/actions"
    }
  }

  var runnersPath: String {
    actionsPath + "/runners"
  }

  func runnerPath(id: Int64) -> String {
    runnersPath + "/\(id)"
  }

  var jitConfigPath: String {
    runnersPath + "/generate-jitconfig"
  }

  static func runnerGroupsPath(org: String) -> String {
    "/orgs/\(escape(org))/actions/runner-groups"
  }

  static func repositoryPath(owner: String, repository: String) -> String {
    "/repos/\(escape(owner))/\(escape(repository))"
  }

  /// Owner and repository names come from configuration, so they are escaped rather than trusted
  /// to be path-safe.
  private static func escape(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? segment
  }

  private static let pathSegmentAllowed: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
  }()
}
