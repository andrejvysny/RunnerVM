import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

/// Fixtures mirror the ones in `github.com/actions/scaleset@v0.4.0`'s own tests, plus one batch
/// carrying all four job-message kinds.
struct ScaleSetMessageDecodingTests {
  @Test func decodesAnEnvelopeWithoutABody() throws {
    let message = try ScaleSetMessageDecoder.decode(
      Data(#"{"messageId":1,"messageType":"RunnerScaleSetJobMessages"}"#.utf8), context: "test"
    )
    #expect(message.messageId == 1)
    #expect(message.messageType == ScaleSetMessage.jobMessagesType)
    #expect(message.body.isEmpty)
    #expect(message.jobMessages.isEmpty)
    #expect(message.statistics == nil)
  }

  @Test func decodesStatistics() throws {
    let raw = """
    {"messageId":7,"messageType":"RunnerScaleSetJobMessages","body":"[]","statistics":\
    {"totalAvailableJobs":1,"totalAcquiredJobs":2,"totalAssignedJobs":3,"totalRunningJobs":4,\
    "totalRegisteredRunners":5,"totalBusyRunners":6,"totalIdleRunners":7}}
    """
    let message = try ScaleSetMessageDecoder.decode(Data(raw.utf8), context: "test")
    #expect(message.statistics == ScaleSetFixture.busyStatistics)
    #expect(message.jobMessages.isEmpty)
  }

  @Test func decodesAllFourJobMessageKinds() throws {
    let body = "[\(ScaleSetFixture.allJobMessages.joined(separator: ","))]"
    let raw = Self.envelope(body: body)
    let message = try ScaleSetMessageDecoder.decode(Data(raw.utf8), context: "test")

    #expect(message.jobMessages.count == 4)

    let available = try #require(message.jobMessages.first)
    #expect(available.messageType == .jobAvailable)
    #expect(available.runnerRequestId == 101)
    #expect(available.acquireJobUrl == "https://actions.invalid/acquire/101")
    #expect(available.repositoryName == "project-a")
    #expect(available.ownerName == "acme")
    #expect(available.jobId == "job-1")
    #expect(available.workflowRunId == 9001)
    #expect(available.eventName == "push")
    #expect(available.requestLabels == ["mac-arm64"])
    #expect(available.queueTime == Date(timeIntervalSince1970: 1_787_652_000))

    let assigned = message.jobMessages[1]
    #expect(assigned.messageType == .jobAssigned)
    // Fractional seconds are part of RFC 3339 and the service does send them.
    #expect(assigned.scaleSetAssignTime != nil)
    #expect(assigned.acquireJobUrl == nil)

    let started = message.jobMessages[2]
    #expect(started.messageType == .jobStarted)
    #expect(started.runnerId == 42)
    #expect(started.runnerName == "runnervm-abc")
    #expect(started.result == nil)

    let completed = message.jobMessages[3]
    #expect(completed.messageType == .jobCompleted)
    #expect(completed.result == "succeeded")
    #expect(completed.runnerId == 43)
    #expect(completed.finishTime != nil)
  }

  @Test func skipsJobMessagesOfAnUnknownKind() throws {
    let body = """
    [{"messageType":"SomethingNew","runnerRequestId":1},\(ScaleSetFixture.jobAssigned)]
    """
    let message = try ScaleSetMessageDecoder.decode(
      Data(Self.envelope(body: body).utf8), context: "test"
    )
    // The protocol is public preview: a new message kind must not stall the poll loop.
    #expect(message.jobMessages.map(\.messageType) == [.jobAssigned])
  }

  @Test func toleratesJobMessagesMissingFields() throws {
    let body = #"[{"messageType":"JobAvailable"}]"#
    let message = try ScaleSetMessageDecoder.decode(
      Data(Self.envelope(body: body).utf8), context: "test"
    )
    let only = try #require(message.jobMessages.first)
    #expect(only.runnerRequestId == 0)
    #expect(only.queueTime == nil)
    #expect(only.repositoryName == nil)
  }

  /// Go marshals an unset `time.Time` as year 1; that means "absent", not a real timestamp.
  @Test func treatsTheGoZeroTimeAsAbsent() throws {
    let body = #"[{"messageType":"JobAssigned","runnerRequestId":5,"finishTime":"0001-01-01T00:00:00Z"}]"#
    let message = try ScaleSetMessageDecoder.decode(
      Data(Self.envelope(body: body).utf8), context: "test"
    )
    #expect(try #require(message.jobMessages.first).finishTime == nil)
  }

  @Test func keepsTheRawBodyForAnUnknownMessageType() throws {
    let raw = #"{"messageId":3,"messageType":"SomethingElse","body":"[]"}"#
    let message = try ScaleSetMessageDecoder.decode(Data(raw.utf8), context: "test")
    #expect(message.messageType == "SomethingElse")
    #expect(message.body == "[]")
    #expect(message.jobMessages.isEmpty)
  }

  @Test func rejectsAnEnvelopeWithoutAMessageID() async {
    let error = await captureError {
      _ = try ScaleSetMessageDecoder.decode(Data(#"{"messageType":"x"}"#.utf8), context: "test")
    }
    #expect(errorClass(of: error!) == .invalidResponse)
  }

  @Test func aMalformedBatchYieldsNoJobMessages() throws {
    let message = try ScaleSetMessageDecoder.decode(
      Data(Self.envelope(body: "not json").utf8), context: "test"
    )
    #expect(message.jobMessages.isEmpty)
    #expect(message.body == "not json")
  }

  /// The body is a JSON *string* holding JSON, so it has to be escaped into the envelope.
  private static func envelope(body: String) -> String {
    let escaped = String(
      data: try! JSONSerialization.data(withJSONObject: [body], options: [.fragmentsAllowed]),
      encoding: .utf8
    )!.dropFirst().dropLast()
    return "{\"messageId\":1,\"messageType\":\"RunnerScaleSetJobMessages\",\"body\":\(escaped)}"
  }
}
