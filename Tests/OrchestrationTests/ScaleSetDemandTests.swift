import Foundation
import GitHubControl
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// M6: the scale-set demand provider — registration, the durable inbox, duplicate delivery and
/// the generation rotation a daemon restart forces (spec §14, §45, §49).
@Suite struct ScaleSetDemandTests {
  @Test func registrationOpensAScaleSetAndAMessageSession() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      try await provider.start()

      let call = try #require(harness.scaleSetPlane.ensureCalls().first)
      #expect(call.name == "runnervm-linux")
      // Jobs target `runs-on: <profile>`; the prefixed scale-set name only namespaces GitHub's side.
      // GitHub keeps the labels from creation, so this must never drift.
      #expect(call.labels == ["linux"])
      #expect(call.disableUpdate)
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      #expect(row.state == "ready")
      #expect(
        row.githubScaleSetId
          == harness.scaleSetPlane.scaleSetID(name: "runnervm-linux", scope: M2Harness.scope))
      let session = try #require(try await harness.scaleSets.currentSession(scaleSetId: row.id))
      #expect(session.sessionGeneration == 0)
      #expect(session.state == "open")
      await provider.stop()
    }
  }

  @Test func aJobMessageIsRecordedAcquiredAndOnlyThenAcknowledged() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      let log = DemandEventLog(provider.events)
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      let messageID = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, jobs: [jobMessage(.jobAvailable, request: 7)],
        statistics: statistics(assigned: 2, available: 1))

      // The cursor is the last durable step of the sequence, so waiting on it means every
      // earlier one — intent, acquisition, DeleteMessage, mark deleted — has already happened.
      try await waitUntil("the cursor to advance past the acknowledged message") {
        try await harness.scaleSets.currentSession(scaleSetId: row.id)?.lastMessageId == messageID
      }
      #expect(harness.scaleSetPlane.deletedMessageIDs().contains(messageID))
      #expect(harness.scaleSetPlane.acquiredIDs() == [7])
      #expect(await provider.snapshot(profile: profile).assignedJobs == 2)
      let inbox = try await harness.scaleSets.intents(scaleSetId: row.id)
      #expect(inbox.count == 1)
      #expect(inbox.first?.status == .deleted)
      #expect(inbox.first?.bodyJson.contains("\"acquired\":[7]") == true)
      let session = try #require(try await harness.scaleSets.currentSession(scaleSetId: row.id))
      #expect(session.lastMessageId == messageID)
      #expect(log.events.contains(.demandChanged(profile: profile)))
      await provider.stop()
      log.stop()
    }
  }

  @Test func jobStartedAndCompletedAreCorrelatedByRunnerName() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      let log = DemandEventLog(provider.events)
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      let started = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID,
        jobs: [jobMessage(.jobStarted, request: 7, runner: "rvm-linux-abc")],
        statistics: statistics(assigned: 1))
      try await waitUntil("JobStarted to be acknowledged") {
        harness.scaleSetPlane.deletedMessageIDs().contains(started)
      }
      let completed = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID,
        jobs: [
          jobMessage(.jobCompleted, request: 7, runner: "rvm-linux-abc", result: "succeeded"),
        ],
        statistics: statistics(assigned: 0))
      try await waitUntil("JobCompleted to be acknowledged") {
        harness.scaleSetPlane.deletedMessageIDs().contains(completed)
      }

      #expect(
        log.events.contains(
          .jobStarted(profile: profile, runnerName: "rvm-linux-abc", requestId: 7)))
      #expect(
        log.events.contains(
          .jobCompleted(
            profile: profile, runnerName: "rvm-linux-abc", requestId: 7, result: "succeeded")))
      #expect(await provider.snapshot(profile: profile).assignedJobs == 0)
      await provider.stop()
      log.stop()
    }
  }

  @Test func aRedeliveredJobIsNotAcquiredTwice() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      let first = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, jobs: [jobMessage(.jobAvailable, request: 7)],
        statistics: statistics(assigned: 1))
      try await waitUntil("the first delivery to be acknowledged") {
        harness.scaleSetPlane.deletedMessageIDs().contains(first)
      }
      // The queue redelivers the same job under a new message id after a lost acknowledgment.
      let second = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, jobs: [jobMessage(.jobAvailable, request: 7)],
        statistics: statistics(assigned: 1))
      try await waitUntil("the redelivery to be acknowledged") {
        harness.scaleSetPlane.deletedMessageIDs().contains(second)
      }

      #expect(harness.scaleSetPlane.acquireCalls().count == 1)
      #expect(harness.scaleSetPlane.acquiredIDs() == [7])
      #expect(try await harness.scaleSets.intents(scaleSetId: row.id).count == 2)
      await provider.stop()
    }
  }

  @Test func restartOpensANewGenerationAndReplaysPendingIntents() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let profile = try await harness.profileID("linux")
      // What a daemon that died between `AcquireJobs` and the acknowledgment leaves behind.
      let row = try await harness.scaleSets.ensureScaleSet(
        profileId: profile, githubScaleSetName: "runnervm-linux")
      _ = try await harness.scaleSets.openSession(scaleSetId: row.id)
      try await harness.scaleSets.recordIntent(
        scaleSetId: row.id, generation: 0, messageId: 5,
        messageType: ScaleSetMessage.jobMessagesType,
        bodyJson: """
          {"acquired":[9],"messages":[{"messageType":"JobAvailable","runnerRequestId":9}]}
          """)

      let provider = harness.demandProvider()
      try await provider.start()

      let session = try #require(try await harness.scaleSets.currentSession(scaleSetId: row.id))
      #expect(session.sessionGeneration == 1)
      #expect(session.lastMessageId == 0)
      let replayed = try await harness.scaleSets.intents(scaleSetId: row.id)
        .first { $0.sessionGeneration == 0 }
      #expect(replayed?.status == .processed)

      // The new session redelivers the job the old one never acknowledged.
      let scaleSetID = try #require(
        try await harness.scaleSets.get(profileId: profile)?.githubScaleSetId)
      let redelivered = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, jobs: [jobMessage(.jobAvailable, request: 9)],
        statistics: statistics(assigned: 1))
      try await waitUntil("the redelivery to be acknowledged") {
        harness.scaleSetPlane.deletedMessageIDs().contains(redelivered)
      }
      #expect(harness.scaleSetPlane.acquireCalls().isEmpty)
      await provider.stop()
    }
  }

  @Test func advertisedCapacityIsSentWithTheNextPoll() async throws {
    try await withHarness { harness in
      try await harness.markScopeHealthy()
      let provider = harness.demandProvider()
      try await provider.start()
      let profile = try await harness.profileID("linux")
      let row = try #require(try await harness.scaleSets.get(profileId: profile))
      let scaleSetID = try #require(row.githubScaleSetId)

      await provider.advertise(profile: profile, capacity: 4)
      let message = harness.scaleSetPlane.enqueue(
        scaleSetID: scaleSetID, statistics: statistics(assigned: 0))
      try await waitUntil("a poll carrying the advertised capacity") {
        harness.scaleSetPlane.deletedMessageIDs().contains(message)
          && harness.scaleSetPlane.lastAdvertisedCapacity(scaleSetID: scaleSetID) == 4
      }
      await provider.stop()
    }
  }
}
