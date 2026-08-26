import Foundation
import RunnerCore

// Contract for the GitHub Actions "runner scale set" protocol (spec §4.1, §14, §50; plan C1
// "Demand inbox rule"). Wire shapes mirror github.com/actions/scaleset v0.4.0 (MIT). The protocol is
// public preview: everything scale-set-specific stays behind these types.

public struct ScaleSetStatistics: Codable, Sendable, Equatable {
  public var totalAvailableJobs: Int64
  public var totalAcquiredJobs: Int64
  public var totalAssignedJobs: Int64
  public var totalRunningJobs: Int64
  public var totalRegisteredRunners: Int64
  public var totalBusyRunners: Int64
  public var totalIdleRunners: Int64

  public init(
    totalAvailableJobs: Int64 = 0, totalAcquiredJobs: Int64 = 0, totalAssignedJobs: Int64 = 0,
    totalRunningJobs: Int64 = 0, totalRegisteredRunners: Int64 = 0, totalBusyRunners: Int64 = 0,
    totalIdleRunners: Int64 = 0
  ) {
    self.totalAvailableJobs = totalAvailableJobs
    self.totalAcquiredJobs = totalAcquiredJobs
    self.totalAssignedJobs = totalAssignedJobs
    self.totalRunningJobs = totalRunningJobs
    self.totalRegisteredRunners = totalRegisteredRunners
    self.totalBusyRunners = totalBusyRunners
    self.totalIdleRunners = totalIdleRunners
  }
}

public struct ScaleSetLabel: Codable, Sendable, Equatable {
  public var type: String
  public var name: String
  public init(type: String = "System", name: String) {
    self.type = type
    self.name = name
  }
}

public struct ScaleSetInfo: Codable, Sendable, Equatable {
  public var id: Int64
  public var name: String
  public var runnerGroupId: Int64
  public var runnerGroupName: String?
  public var labels: [ScaleSetLabel]
  public var runnerJitConfigUrl: String?
  public var statistics: ScaleSetStatistics?

  public init(
    id: Int64, name: String, runnerGroupId: Int64, runnerGroupName: String? = nil,
    labels: [ScaleSetLabel] = [], runnerJitConfigUrl: String? = nil, statistics: ScaleSetStatistics? = nil
  ) {
    self.id = id
    self.name = name
    self.runnerGroupId = runnerGroupId
    self.runnerGroupName = runnerGroupName
    self.labels = labels
    self.runnerJitConfigUrl = runnerJitConfigUrl
    self.statistics = statistics
  }
}

/// One job lifecycle message. `messageType` ∈ JobAvailable | JobAssigned | JobStarted | JobCompleted.
public struct ScaleSetJobMessage: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable {
    case jobAvailable = "JobAvailable"
    case jobAssigned = "JobAssigned"
    case jobStarted = "JobStarted"
    case jobCompleted = "JobCompleted"
  }

  public var messageType: Kind
  public var runnerRequestId: Int64
  public var repositoryName: String?
  public var ownerName: String?
  public var jobId: String?
  public var jobWorkflowRef: String?
  public var jobDisplayName: String?
  public var workflowRunId: Int64?
  public var eventName: String?
  public var requestLabels: [String]?
  public var queueTime: Date?
  public var scaleSetAssignTime: Date?
  public var runnerAssignTime: Date?
  public var finishTime: Date?
  /// JobAvailable only.
  public var acquireJobUrl: String?
  /// JobStarted / JobCompleted only.
  public var runnerId: Int64?
  public var runnerName: String?
  /// JobCompleted only.
  public var result: String?

  public init(messageType: Kind, runnerRequestId: Int64) {
    self.messageType = messageType
    self.runnerRequestId = runnerRequestId
  }
}

/// A queue message. `body` is the raw JSON (a JSON array of `ScaleSetJobMessage` when
/// `messageType == "RunnerScaleSetJobMessages"`); `jobMessages` is the parsed form.
public struct ScaleSetMessage: Sendable, Equatable {
  public static let jobMessagesType = "RunnerScaleSetJobMessages"

  public var messageId: Int64
  public var messageType: String
  public var body: String
  public var statistics: ScaleSetStatistics?
  public var jobMessages: [ScaleSetJobMessage]

  public init(
    messageId: Int64, messageType: String, body: String, statistics: ScaleSetStatistics?,
    jobMessages: [ScaleSetJobMessage]
  ) {
    self.messageId = messageId
    self.messageType = messageType
    self.body = body
    self.statistics = statistics
    self.jobMessages = jobMessages
  }
}

public struct ScaleSetRunnerReference: Codable, Sendable, Equatable {
  public var id: Int64
  public var name: String
  public var runnerScaleSetId: Int64
  public init(id: Int64, name: String, runnerScaleSetId: Int64) {
    self.id = id
    self.name = name
    self.runnerScaleSetId = runnerScaleSetId
  }
}

/// Message-session facts safe to persist/log. The queue access token is NOT part of this type.
public struct ScaleSetSessionInfo: Sendable, Equatable {
  public var sessionId: String
  public var ownerName: String
  public var scaleSetId: Int64
  public var statistics: ScaleSetStatistics?
  public init(sessionId: String, ownerName: String, scaleSetId: Int64, statistics: ScaleSetStatistics?) {
    self.sessionId = sessionId
    self.ownerName = ownerName
    self.scaleSetId = scaleSetId
    self.statistics = statistics
  }
}

/// One open message session. Implementations own the queue URL + access token, refresh them on 401
/// (same session, same cursor), and long-poll ~50 s per `getMessage`.
public protocol ScaleSetSession: AnyObject, Sendable {
  var info: ScaleSetSessionInfo { get async }
  /// nil when the poll returned no message (HTTP 202). `maxCapacity` is sent as `X-ScaleSetMaxCapacity`.
  func getMessage(lastMessageID: Int64, maxCapacity: Int) async throws -> ScaleSetMessage?
  /// Acknowledge; unacknowledged messages are redelivered. 404 is treated as success.
  func deleteMessage(id: Int64) async throws
  /// Returns the subset of request ids actually acquired.
  func acquireJobs(requestIDs: [Int64]) async throws -> [Int64]
  func close() async throws
}

/// Spec §50 control plane for the scale-set demand model. One implementation per GitHub scope
/// (organization or repository config URL); the Actions-service token exchange lives inside.
public protocol ScaleSetControlPlane: Sendable {
  func ensureScaleSet(
    scope: GitHubScope, name: String, runnerGroupID: Int64, labels: [String], disableUpdate: Bool
  ) async throws -> ScaleSetInfo
  func getScaleSet(scope: GitHubScope, runnerGroupID: Int64, name: String) async throws -> ScaleSetInfo?
  func deleteScaleSet(scope: GitHubScope, id: Int64) async throws
  func openSession(scope: GitHubScope, scaleSetID: Int64, owner: String) async throws -> any ScaleSetSession
  /// Scale-set JIT config: the runner is bound to the scale set, not to a job.
  func generateJITConfig(
    scope: GitHubScope, scaleSetID: Int64, runnerName: String, workFolder: String
  ) async throws -> JITRunnerConfig
  func runner(scope: GitHubScope, id: Int64) async throws -> ScaleSetRunnerReference?
  /// Idempotent (404 ⇒ success).
  func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws
}
