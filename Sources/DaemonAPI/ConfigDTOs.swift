import Foundation
import RunnerCore

public struct ConfigValidateRequest: Codable, Sendable, Hashable {
  public var yaml: String

  public init(yaml: String) { self.yaml = yaml }
}

public struct ConfigValidateResponse: Codable, Sendable, Hashable {
  public var valid: Bool
  public var issues: [ConfigurationIssue]

  public init(issues: [ConfigurationIssue]) {
    self.issues = issues
    self.valid = !issues.hasErrors
  }
}

public struct ConfigApplyRequest: Codable, Sendable, Hashable {
  public var yaml: String

  public init(yaml: String) { self.yaml = yaml }
}

public struct ConfigApplyResponse: Codable, Sendable, Hashable {
  public var diff: ConfigDiff
  public var operationId: String
  /// Warnings only; an apply carrying errors is rejected before it reaches the database.
  public var issues: [ConfigurationIssue]
  public var appliedAt: String

  public init(
    diff: ConfigDiff, operationId: String, issues: [ConfigurationIssue], appliedAt: String
  ) {
    self.diff = diff
    self.operationId = operationId
    self.issues = issues
    self.appliedAt = appliedAt
  }
}

public struct ConfigGetResponse: Codable, Sendable, Hashable {
  public var yaml: String?
  public var appliedAt: String?

  public init(yaml: String? = nil, appliedAt: String? = nil) {
    self.yaml = yaml
    self.appliedAt = appliedAt
  }
}

/// Desired-state delta of a `config.apply` (spec §64 step 3). Removal disables rather than
/// deletes, so an operator can restore a profile by putting it back in the document.
public struct ConfigDiff: Codable, Sendable, Hashable {
  public var addedScopes: [String]
  public var updatedScopes: [String]
  public var disabledScopes: [String]
  public var addedProfiles: [String]
  public var updatedProfiles: [String]
  public var disabledProfiles: [String]

  public init(
    addedScopes: [String] = [], updatedScopes: [String] = [], disabledScopes: [String] = [],
    addedProfiles: [String] = [], updatedProfiles: [String] = [], disabledProfiles: [String] = []
  ) {
    self.addedScopes = addedScopes
    self.updatedScopes = updatedScopes
    self.disabledScopes = disabledScopes
    self.addedProfiles = addedProfiles
    self.updatedProfiles = updatedProfiles
    self.disabledProfiles = disabledProfiles
  }

  public var isEmpty: Bool {
    addedScopes.isEmpty && updatedScopes.isEmpty && disabledScopes.isEmpty
      && addedProfiles.isEmpty && updatedProfiles.isEmpty && disabledProfiles.isEmpty
  }

  public var changeCount: Int {
    addedScopes.count + updatedScopes.count + disabledScopes.count
      + addedProfiles.count + updatedProfiles.count + disabledProfiles.count
  }
}
