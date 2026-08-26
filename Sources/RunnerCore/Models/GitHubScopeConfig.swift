import Foundation

/// GitHub target a profile registers runners against (spec §11).
public enum GitHubScopeKind: String, Codable, Sendable, CaseIterable, Hashable {
  case organization
  case repository
}

/// Validated in-memory form of a `github.scopes[]` entry. YAML spells `kind` as `type`;
/// that mapping belongs to ConfigLoader so this model stays clean camelCase.
public struct GitHubScopeConfig: Codable, Sendable, Hashable {
  /// Local alias referenced by `RunnerProfileConfig.scope`. Unique across the configuration.
  public var name: String
  public var kind: GitHubScopeKind
  public var owner: String
  /// Required when `kind == .repository`, ignored otherwise.
  public var repository: String?
  /// Organization runner group. Resolved to an id by GitHubControl at apply time.
  public var runnerGroup: String?

  public init(
    name: String,
    kind: GitHubScopeKind,
    owner: String,
    repository: String? = nil,
    runnerGroup: String? = nil
  ) {
    self.name = name
    self.kind = kind
    self.owner = owner
    self.repository = repository
    self.runnerGroup = runnerGroup
  }

  /// `acme` or `acme/project-a`, the form used in GitHub API paths.
  public var slug: String {
    switch kind {
    case .organization: owner
    case .repository: "\(owner)/\(repository ?? "")"
    }
  }
}
