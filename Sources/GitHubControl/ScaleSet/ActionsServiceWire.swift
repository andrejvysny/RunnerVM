// Ported from github.com/actions/scaleset@v0.4.0 (MIT) types.go — see PROVENANCE.md.

import Foundation
import RunnerCore

/// JSON shapes of the Actions service ("runner scale set") API. Internal on purpose: nothing
/// outside GitHubControl sees the Actions service wire format (spec §50).
///
/// The names are the service's, not RunnerVM's — including `RunnerSetting`, which really is
/// capitalised on the wire, and `runnerScaleSetId`, which is spelled differently from REST's
/// `runner_group_id`.
enum ActionsWire {
  struct Label: Codable, Sendable {
    var type: String?
    var name: String
  }

  struct RunnerSetting: Codable, Sendable {
    var disableUpdate: Bool?
  }

  struct RunnerScaleSet: Codable, Sendable {
    var id: Int64?
    var name: String?
    var runnerGroupId: Int64?
    var runnerGroupName: String?
    var labels: [Label]?
    var runnerSetting: RunnerSetting?
    var runnerJitConfigUrl: String?
    var statistics: Statistic?

    enum CodingKeys: String, CodingKey {
      case id, name, runnerGroupId, runnerGroupName, labels, runnerJitConfigUrl, statistics
      case runnerSetting = "RunnerSetting"
    }
  }

  struct RunnerScaleSetList: Codable, Sendable {
    var count: Int?
    var value: [RunnerScaleSet]?
  }

  struct Statistic: Codable, Sendable {
    var totalAvailableJobs: Int64?
    var totalAcquiredJobs: Int64?
    var totalAssignedJobs: Int64?
    var totalRunningJobs: Int64?
    var totalRegisteredRunners: Int64?
    var totalBusyRunners: Int64?
    var totalIdleRunners: Int64?
  }

  struct RunnerGroup: Codable, Sendable {
    var id: Int64?
    var name: String?
    var size: Int?
    var isDefaultGroup: Bool?
  }

  struct RunnerGroupList: Codable, Sendable {
    var count: Int?
    var value: [RunnerGroup]?
  }

  struct Session: Codable, Sendable {
    var sessionId: String?
    var ownerName: String?
    var runnerScaleSet: RunnerScaleSet?
    var messageQueueUrl: String?
    var messageQueueAccessToken: String?
    var statistics: Statistic?
  }

  struct MessageResponse: Codable, Sendable {
    var messageId: Int64?
    var messageType: String?
    var body: String?
    var statistics: Statistic?
  }

  struct AcquireJobsResponse: Codable, Sendable {
    var count: Int?
    var value: [Int64]?
  }

  struct RunnerReference: Codable, Sendable {
    var id: Int64?
    var name: String?
    var runnerScaleSetId: Int64?
  }

  struct RunnerReferenceList: Codable, Sendable {
    var count: Int?
    var value: [RunnerReference]?
  }

  struct JitRunnerSetting: Codable, Sendable {
    var name: String
    var workFolder: String
  }

  struct JitRunnerConfig: Codable, Sendable {
    var runner: RunnerReference?
    var encodedJITConfig: String?
  }

  /// The Actions service error envelope (a .NET exception, not GitHub's REST `{message}`).
  struct ExceptionBody: Decodable, Sendable {
    var typeName: String?
    var message: String?
  }

  /// `POST /actions/runner-registration` response.
  struct AdminConnection: Decodable, Sendable {
    var url: String?
    var token: String?
  }

  /// `POST /{scope}/actions/runners/registration-token` response.
  struct RegistrationToken: Decodable, Sendable {
    var token: String?
  }
}

// MARK: - Domain mapping

extension ActionsWire.Statistic {
  var domain: ScaleSetStatistics {
    ScaleSetStatistics(
      totalAvailableJobs: totalAvailableJobs ?? 0,
      totalAcquiredJobs: totalAcquiredJobs ?? 0,
      totalAssignedJobs: totalAssignedJobs ?? 0,
      totalRunningJobs: totalRunningJobs ?? 0,
      totalRegisteredRunners: totalRegisteredRunners ?? 0,
      totalBusyRunners: totalBusyRunners ?? 0,
      totalIdleRunners: totalIdleRunners ?? 0
    )
  }
}

extension ActionsWire.RunnerScaleSet {
  func domain(context: String) throws -> ScaleSetInfo {
    guard let id, let name else {
      throw GitHubControlError.invalidResponse(
        reason: "\(context): runner scale set is missing an id or a name"
      )
    }
    return ScaleSetInfo(
      id: id,
      name: name,
      runnerGroupId: runnerGroupId ?? GitHubScope.defaultRunnerGroupID,
      runnerGroupName: runnerGroupName,
      labels: (labels ?? []).map { ScaleSetLabel(type: $0.type ?? "System", name: $0.name) },
      runnerJitConfigUrl: runnerJitConfigUrl,
      statistics: statistics?.domain
    )
  }
}

extension ActionsWire.RunnerReference {
  func domain(context: String) throws -> ScaleSetRunnerReference {
    guard let id, let name else {
      throw GitHubControlError.invalidResponse(
        reason: "\(context): runner reference is missing an id or a name"
      )
    }
    return ScaleSetRunnerReference(id: id, name: name, runnerScaleSetId: runnerScaleSetId ?? 0)
  }
}
