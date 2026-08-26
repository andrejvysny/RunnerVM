import Foundation
import RunnerCore

public extension GitHubScope {
  /// Group id the configuration resolved earlier, if any. Distinct from `runnerGroupID`, which
  /// substitutes GitHub's default when nothing was configured.
  var configuredRunnerGroupID: Int64? {
    switch self {
    case let .organization(_, id): id
    case .repository: nil
    }
  }
}

extension GitHubRunnersAPI {
  /// The cheap health probe behind `runnerctl github test` and scope reconciliation (spec §134,
  /// §148). Never throws: a broken scope is a state the scheduler reacts to by refusing to place
  /// work there, not an error that aborts the reconcile pass.
  public func checkPermissions(
    scope: GitHubScope, runnerGroup: String? = nil, allowPublicRepositories: Bool = false
  ) async -> GitHubScopeHealth {
    var problems: [GitHubScopeHealth.Problem] = []
    var runnerCount: Int?
    do {
      runnerCount = try await listRunners(scope: scope).count
    } catch {
      problems.append(Self.problem(error))
    }

    var runnerGroupID = scope.configuredRunnerGroupID
    var visibility: RepositoryVisibility?
    switch scope {
    case let .organization(owner, _):
      guard let runnerGroup else { break }
      do {
        runnerGroupID = try await resolveRunnerGroupID(org: owner, name: runnerGroup)
      } catch {
        problems.append(Self.problem(error))
      }
    case let .repository(owner, repository):
      do {
        let seen = try await repositoryVisibility(owner: owner, repository: repository)
        visibility = seen
        if seen.isPublic, !allowPublicRepositories {
          problems.append(
            GitHubScopeHealth.Problem(GitHubControlError.publicRepositoryNotAllowed(scope: scope.slug))
          )
        }
      } catch {
        problems.append(Self.problem(error))
      }
    }

    return GitHubScopeHealth(
      scope: scope.description, problems: problems, runnerGroupID: runnerGroupID,
      visibility: visibility, runnerCount: runnerCount
    )
  }

  static func problem(_ error: any Error) -> GitHubScopeHealth.Problem {
    if let error = error as? GitHubControlError { return GitHubScopeHealth.Problem(error) }
    return GitHubScopeHealth.Problem(
      code: "GITHUB_UNEXPECTED_ERROR", errorClass: nil, detail: "\(error)"
    )
  }
}
