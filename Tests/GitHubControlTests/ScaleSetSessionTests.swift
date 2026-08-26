import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

struct ActionsMessageSessionTests {
  @Test func opensASessionAndReportsWhatIsSafeToPersist() async throws {
    try await withOpenSession { harness, scaleSetID, session in
      let info = await session.info
      #expect(!info.sessionId.isEmpty)
      #expect(info.ownerName == "acme")
      #expect(info.scaleSetId == scaleSetID)

      let created = try #require(harness.service.requests("POST", containing: "/sessions").first)
      #expect(created.bodyValue("ownerName") as? String == "acme")
      #expect(created.query["api-version"] == "6.0-preview")
      #expect(harness.service.openSessionIDs == [info.sessionId])
    }
  }

  @Test func anEmptyQueueYieldsNoMessage() async throws {
    try await withOpenSession { harness, _, session in
      // HTTP 202: the service held the poll for its window and had nothing to hand over.
      let empty = try await session.getMessage(lastMessageID: 0, maxCapacity: 4)
      #expect(empty == nil)
      #expect(harness.service.requests("GET", containing: "/queue/").count == 1)
    }
  }

  @Test func advertisesMaxCapacityOnEveryPoll() async throws {
    try await withOpenSession { harness, _, session in
      _ = try await session.getMessage(lastMessageID: 0, maxCapacity: 6)
      let poll = try #require(harness.service.requests("GET", containing: "/queue/").first)
      #expect(poll.header(ActionsMessageSession.maxCapacityHeader) == "6")
      #expect(poll.header("Accept") == "application/json; api-version=6.0-preview")
      #expect(poll.header("Authorization") == "Bearer queue-token-1")
      // The cursor is omitted at zero, so the service replays from the oldest unacknowledged.
      #expect(poll.query["lastMessageId"] == nil)
    }
  }

  @Test func parsesTheJobMessageBatchAndTheStatistics() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(
        jobMessages: ScaleSetFixture.allJobMessages, statistics: ScaleSetFixture.busyStatistics
      )

      let message = try #require(
        await session.getMessage(lastMessageID: 0, maxCapacity: 4)
      )
      #expect(message.messageId == 1)
      #expect(message.messageType == ScaleSetMessage.jobMessagesType)
      #expect(message.statistics == ScaleSetFixture.busyStatistics)
      #expect(message.jobMessages.map(\.messageType) == [
        .jobAvailable, .jobAssigned, .jobStarted, .jobCompleted,
      ])
      #expect(message.jobMessages.map(\.runnerRequestId) == [101, 102, 103, 104])
      // Statistics, not message counts, drive scaling; the session keeps the latest.
      #expect(await session.info.statistics == ScaleSetFixture.busyStatistics)
    }
  }

  @Test func redeliversUntilTheMessageIsAcknowledged() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAvailable])

      let first = try #require(await session.getMessage(lastMessageID: 0, maxCapacity: 4))
      let again = try #require(await session.getMessage(lastMessageID: 0, maxCapacity: 4))
      #expect(first.messageId == again.messageId)

      try await session.deleteMessage(id: first.messageId)
      #expect(harness.service.unacknowledgedMessageIDs.isEmpty)
      let drained = try await session.getMessage(lastMessageID: 0, maxCapacity: 4)
      #expect(drained == nil)
    }
  }

  @Test func theCursorSkipsMessagesAlreadyProcessed() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAvailable])
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAssigned])

      let second = try #require(await session.getMessage(lastMessageID: 1, maxCapacity: 4))
      #expect(second.messageId == 2)
      #expect(second.jobMessages.map(\.runnerRequestId) == [102])

      let poll = try #require(harness.service.requests("GET", containing: "/queue/").first)
      #expect(poll.query["lastMessageId"] == "1")
    }
  }

  @Test func refreshesTheSessionOnAnExpiredQueueTokenAndKeepsTheCursor() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAvailable])
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAssigned])
      harness.service.expireQueueToken()

      let message = try #require(await session.getMessage(lastMessageID: 1, maxCapacity: 4))
      #expect(message.messageId == 2)

      let polls = harness.service.requests("GET", containing: "/queue/")
      #expect(polls.count == 2)
      // Same session, same cursor: a refresh must not lose the client's place.
      #expect(polls.allSatisfy { $0.query["lastMessageId"] == "1" })
      #expect(harness.service.requests("PATCH", containing: "/sessions/").count == 1)
      #expect(polls.last?.header("Authorization") == "Bearer queue-token-2")
      #expect(harness.service.openSessionIDs.count == 1)
    }
  }

  @Test func aSecondUnauthorizedMeansTheSessionIsDead() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAvailable])
      harness.service.expireQueueToken(times: 2)

      let error = await captureError {
        _ = try await session.getMessage(lastMessageID: 0, maxCapacity: 4)
      }
      let failure = try #require(error as? GitHubControlError)
      #expect(failure.code == "GITHUB_SCALE_SET_SESSION_EXPIRED")
      // Recoverable by opening a new session, so the listener retries rather than gives up.
      #expect(failure.errorClass == .transientServer)
    }
  }

  @Test func acknowledgingAMissingMessageSucceeds() async throws {
    try await withOpenSession { _, _, session in
      try await session.deleteMessage(id: 999)
    }
  }

  @Test func refreshesTheSessionWhenAcknowledgementIsUnauthorized() async throws {
    try await withOpenSession { harness, _, session in
      harness.service.enqueue(jobMessages: [ScaleSetFixture.jobAvailable])
      let message = try #require(await session.getMessage(lastMessageID: 0, maxCapacity: 4))
      harness.service.expireQueueToken()

      try await session.deleteMessage(id: message.messageId)
      #expect(harness.service.unacknowledgedMessageIDs.isEmpty)
      #expect(harness.service.requests("PATCH", containing: "/sessions/").count == 1)
    }
  }

  // MARK: - Job acquisition

  @Test func acquiresOnlyTheJobsTheServiceGrants() async throws {
    try await withOpenSession { harness, scaleSetID, session in
      harness.service.setAcquirable([101, 103])

      let won = try await session.acquireJobs(requestIDs: [101, 102, 103])
      #expect(won == [101, 103])

      let request = try #require(
        harness.service.requests("POST", containing: "\(scaleSetID)/acquirejobs").first
      )
      // Authorised with the message-queue token, not the admin token.
      #expect(request.header("Authorization") == "Bearer queue-token-1")
      let body = try #require(request.body)
      #expect(try JSONDecoder().decode([Int64].self, from: body) == [101, 102, 103])
    }
  }

  @Test func acquiringNothingSkipsTheCall() async throws {
    try await withOpenSession { harness, _, session in
      let none = try await session.acquireJobs(requestIDs: [])
      #expect(none.isEmpty)
      #expect(harness.service.requests("POST", containing: "acquirejobs").isEmpty)
    }
  }

  // MARK: - Lifecycle

  @Test func closingDeletesTheSessionAndIsIdempotent() async throws {
    try await withOpenSession { harness, _, session in
      try await session.close()
      #expect(harness.service.openSessionIDs.isEmpty)
      try await session.close()
      #expect(harness.service.requests("DELETE", containing: "/sessions/").count == 1)
    }
  }
}
