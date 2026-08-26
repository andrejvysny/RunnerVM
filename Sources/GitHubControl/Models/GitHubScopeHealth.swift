import Foundation
import RunnerCore

/// Result of probing one scope's credentials and permissions (spec §134, §135, §148).
/// Produced by a call that never throws: a broken scope is data the scheduler acts on, not an
/// error that aborts a reconcile pass.
public struct GitHubScopeHealth: Sendable, Hashable {
  /// Machine-readable, so scheduler and `runnerctl status` never parse `detail`.
  public struct Problem: Sendable, Hashable, CustomStringConvertible {
    public let code: String
    public let errorClass: GitHubErrorClass?
    public let detail: String

    public init(code: String, errorClass: GitHubErrorClass?, detail: String) {
      self.code = code
      self.errorClass = errorClass
      self.detail = detail
    }

    public init(_ error: GitHubControlError) {
      self.init(code: error.code, errorClass: error.errorClass, detail: error.message)
    }

    public var description: String {
      "\(code): \(detail)"
    }
  }

  /// Spec §135 vocabulary.
  public enum Status: String, Sendable, Hashable, CaseIterable {
    case healthy, degraded, unhealthy, unknown
  }

  public let scope: String
  public let problems: [Problem]
  /// Resolved organization runner group, when one was requested (spec §134).
  public let runnerGroupID: Int64?
  public let visibility: RepositoryVisibility?
  /// Runners GitHub currently knows about in this scope; `nil` when the listing itself failed.
  public let runnerCount: Int?

  public init(
    scope: String, problems: [Problem] = [], runnerGroupID: Int64? = nil,
    visibility: RepositoryVisibility? = nil, runnerCount: Int? = nil
  ) {
    self.scope = scope
    self.problems = problems
    self.runnerGroupID = runnerGroupID
    self.visibility = visibility
    self.runnerCount = runnerCount
  }

  public var ok: Bool {
    problems.isEmpty
  }

  /// A credential or permission fault is terminal until an operator acts; anything else (rate
  /// limit, 5xx, socket) is expected to clear on its own.
  public var status: Status {
    guard !problems.isEmpty else { return .healthy }
    let terminal: Set<GitHubErrorClass> = [
      .authentication, .authorization, .notFound, .permanentConfiguration, .conflict,
    ]
    if problems.contains(where: { $0.errorClass.map(terminal.contains) ?? false }) {
      return .unhealthy
    }
    return .degraded
  }
}
