// Ported from github.com/actions/scaleset@v0.4.0 (MIT) client.go
// (`parseRunnerScaleSetMessageResponse`) — see PROVENANCE.md.

import Foundation
import RunnerCore

/// Turns a message-queue response into `ScaleSetMessage`.
///
/// The queue nests JSON inside JSON: the envelope's `body` is a *string* holding a JSON array of
/// job messages when `messageType == "RunnerScaleSetJobMessages"`. Everything below the envelope is
/// decoded leniently — the service adds fields, and a message RunnerVM cannot fully parse must not
/// stall the poll loop (spec §50: the scale-set protocol is public preview).
enum ScaleSetMessageDecoder {
  static func decode(_ data: Data, context: String) throws -> ScaleSetMessage {
    let envelope: ActionsWire.MessageResponse
    do {
      envelope = try JSONDecoder().decode(ActionsWire.MessageResponse.self, from: data)
    } catch {
      throw GitHubControlError.invalidResponse(
        reason: "\(context): message envelope is not valid JSON"
      )
    }
    guard let messageId = envelope.messageId else {
      throw GitHubControlError.invalidResponse(reason: "\(context): message has no messageId")
    }
    let type = envelope.messageType ?? ""
    let body = envelope.body ?? ""
    return ScaleSetMessage(
      messageId: messageId,
      messageType: type,
      body: body,
      statistics: envelope.statistics?.domain,
      jobMessages: type == ScaleSetMessage.jobMessagesType ? jobMessages(in: body) : []
    )
  }

  /// Unknown or malformed entries are dropped rather than failing the batch, matching the Go
  /// client's `default:` fall-through for unrecognised message types.
  static func jobMessages(in body: String) -> [ScaleSetJobMessage] {
    guard !body.isEmpty, let data = body.data(using: .utf8) else { return [] }
    guard let entries = try? JSONDecoder().decode([JobMessageWire].self, from: data) else {
      return []
    }
    let dates = ActionsDateParser()
    return entries.compactMap { $0.domain(dates: dates) }
  }
}

/// Every field optional: the four job-message kinds share one envelope and differ only by which
/// fields they populate.
private struct JobMessageWire: Decodable {
  var messageType: String?
  var runnerRequestId: Int64?
  var repositoryName: String?
  var ownerName: String?
  var jobId: String?
  var jobWorkflowRef: String?
  var jobDisplayName: String?
  var workflowRunId: Int64?
  var eventName: String?
  var requestLabels: [String]?
  var queueTime: String?
  var scaleSetAssignTime: String?
  var runnerAssignTime: String?
  var finishTime: String?
  var acquireJobUrl: String?
  var runnerId: Int64?
  var runnerName: String?
  var result: String?

  func domain(dates: ActionsDateParser) -> ScaleSetJobMessage? {
    guard let raw = messageType, let kind = ScaleSetJobMessage.Kind(rawValue: raw) else {
      return nil
    }
    var message = ScaleSetJobMessage(messageType: kind, runnerRequestId: runnerRequestId ?? 0)
    message.repositoryName = repositoryName
    message.ownerName = ownerName
    message.jobId = jobId
    message.jobWorkflowRef = jobWorkflowRef
    message.jobDisplayName = jobDisplayName
    message.workflowRunId = workflowRunId
    message.eventName = eventName
    message.requestLabels = requestLabels
    message.queueTime = dates.parse(queueTime)
    message.scaleSetAssignTime = dates.parse(scaleSetAssignTime)
    message.runnerAssignTime = dates.parse(runnerAssignTime)
    message.finishTime = dates.parse(finishTime)
    message.acquireJobUrl = acquireJobUrl
    message.runnerId = runnerId
    message.runnerName = runnerName
    message.result = result
    return message
  }
}

/// RFC 3339 with and without fractional seconds. `ISO8601DateFormatter` is neither `Sendable` nor
/// cheap to build, so one parser is created per batch and passed down.
struct ActionsDateParser {
  private let fractional: ISO8601DateFormatter
  private let plain: ISO8601DateFormatter

  init() {
    fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
  }

  func parse(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    // Go marshals an unset `time.Time` as its zero value; that is "absent", not "year 1".
    guard !value.hasPrefix("0001-01-01") else { return nil }
    return fractional.date(from: value) ?? plain.date(from: value)
  }
}
