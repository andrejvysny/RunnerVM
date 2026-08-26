import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

struct ActionsScaleSetClientTests {
  // MARK: - Token exchange (spec §50)

  @Test func exchangesARegistrationTokenForTheActionsAdminConnection() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      _ = try await harness.client.getScaleSet(
        scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
      )

      let registration = try #require(
        harness.service.requests("POST", containing: "/runners/registration-token").first
      )
      #expect(registration.path == "/orgs/acme/actions/runners/registration-token")

      let exchange = try #require(
        harness.service.requests("POST", containing: "/actions/runner-registration").first
      )
      #expect(exchange.header("Authorization") == "RemoteAuth registration-token-1")
      #expect(exchange.header("Content-Type") == "application/json")
      #expect(
        exchange.bodyValue("url") as? String == "\(harness.service.configBaseURL.absoluteString)/acme"
      )
      #expect(exchange.bodyValue("runner_event") as? String == "register")
    }
  }

  @Test func buildsTheConfigURLFromTheRepositoryScope() async throws {
    try await withScaleSetHarness { harness in
      let scope = Fixture.repositoryScope
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      _ = try await harness.client.getScaleSet(
        scope: scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
      )

      let registration = try #require(
        harness.service.requests("POST", containing: "/runners/registration-token").first
      )
      #expect(registration.path == "/repos/acme/project-a/actions/runners/registration-token")
      let exchange = try #require(
        harness.service.requests("POST", containing: "/actions/runner-registration").first
      )
      #expect(
        exchange.bodyValue("url") as? String
          == "\(harness.service.configBaseURL.absoluteString)/acme/project-a"
      )
    }
  }

  @Test func reusesTheAdminTokenUntilItIsAboutToExpire() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      for _ in 0 ..< 3 {
        _ = try await harness.client.getScaleSet(
          scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
        )
      }
      #expect(harness.service.adminExchangeRequests == 1)
      #expect(harness.service.registrationTokenRequests == 1)
    }
  }

  /// The JWT's `exp` drives the refresh: a token that dies inside the margin is replaced first.
  @Test func refreshesTheAdminTokenBeforeItsExpiry() async throws {
    try await withScaleSetHarness { harness in
      harness.service.setAdminTokenLifetime(30)
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      for _ in 0 ..< 3 {
        _ = try await harness.client.getScaleSet(
          scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
        )
      }
      #expect(harness.service.adminExchangeRequests == 3)
      #expect(harness.service.registrationTokenRequests == 3)
    }
  }

  @Test func sendsTheApiVersionAndTheSystemInfoUserAgent() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      _ = try await harness.client.getScaleSet(
        scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
      )

      let tenant = try #require(
        harness.service.requests("GET", containing: "_apis/runtime/runnerscalesets").first
      )
      #expect(tenant.query["api-version"] == "6.0-preview")
      #expect(tenant.query["runnerGroupId"] == "1")
      #expect(tenant.query["name"] == ScaleSetFixture.scaleSetName)
      #expect(tenant.header("Authorization")?.hasPrefix("Bearer ") == true)
      let agent = try #require(tenant.header("User-Agent"))
      #expect(agent.contains("\"system\":\"runnervm\""))
      #expect(agent.contains("\"subsystem\":\"runnerd\""))
      #expect(agent.contains("\"kind\":\"scaleset\""))
      #expect(agent.contains("\"scale_set_id\":1"))
    }
  }

  // MARK: - ensureScaleSet

  @Test func createsAScaleSetWhenNoneExists() async throws {
    try await withScaleSetHarness { harness in
      let info = try await harness.client.ensureScaleSet(
        scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1, labels: [],
        disableUpdate: true
      )

      #expect(info.name == ScaleSetFixture.scaleSetName)
      #expect(info.runnerGroupId == 1)
      // An empty label list defaults to the scale set's own name, the label `runs-on` targets.
      #expect(info.labels == [ScaleSetLabel(type: "System", name: ScaleSetFixture.scaleSetName)])

      let created = try #require(
        harness.service.requests("POST", containing: "_apis/runtime/runnerscalesets").first
      )
      #expect(created.bodyValue("name") as? String == ScaleSetFixture.scaleSetName)
      #expect(created.bodyValue("runnerGroupId") as? Int == 1)
      let labels = try #require(created.bodyValue("labels") as? [[String: String]])
      #expect(labels == [["type": "System", "name": ScaleSetFixture.scaleSetName]])
      let setting = try #require(created.bodyValue("RunnerSetting") as? [String: Bool])
      #expect(setting == ["disableUpdate": true])
      #expect(harness.service.scaleSetNames == [ScaleSetFixture.scaleSetName])
    }
  }

  @Test func leavesAMatchingScaleSetAlone() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(
        name: ScaleSetFixture.scaleSetName, labels: ["mac-arm64"], disableUpdate: true
      )

      let info = try await harness.client.ensureScaleSet(
        scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1,
        labels: ["mac-arm64"], disableUpdate: true
      )

      #expect(info.id == id)
      #expect(harness.service.requests("POST", containing: "runnerscalesets").isEmpty)
      #expect(harness.service.requests("PATCH", containing: "runnerscalesets").isEmpty)
    }
  }

  @Test func patchesAScaleSetWhoseLabelsDrifted() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(
        name: ScaleSetFixture.scaleSetName, labels: ["stale-label"]
      )

      let info = try await harness.client.ensureScaleSet(
        scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1,
        labels: ["mac-arm64", "macos-15"], disableUpdate: false
      )

      #expect(info.id == id)
      #expect(info.labels.map(\.name) == ["mac-arm64", "macos-15"])
      let patch = try #require(
        harness.service.requests("PATCH", containing: "runnerscalesets/\(id)").first
      )
      let labels = try #require(patch.bodyValue("labels") as? [[String: String]])
      #expect(labels.map { $0["name"] } == ["mac-arm64", "macos-15"])
    }
  }

  @Test func patchesAScaleSetWhoseRunnerSettingDrifted() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(
        name: ScaleSetFixture.scaleSetName, labels: ["mac-arm64"], disableUpdate: false
      )

      _ = try await harness.client.ensureScaleSet(
        scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1,
        labels: ["mac-arm64"], disableUpdate: true
      )

      let patch = try #require(
        harness.service.requests("PATCH", containing: "runnerscalesets/\(id)").first
      )
      #expect(patch.bodyValue("RunnerSetting") as? [String: Bool] == ["disableUpdate": true])
    }
  }

  @Test func labelComparisonIgnoresCaseAndOrder() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(
        name: ScaleSetFixture.scaleSetName, labels: ["macOS-15", "mac-arm64"]
      )

      _ = try await harness.client.ensureScaleSet(
        scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1,
        labels: ["mac-arm64", "macos-15"], disableUpdate: false
      )

      #expect(harness.service.requests("PATCH", containing: "runnerscalesets").isEmpty)
    }
  }

  @Test func aScaleSetInAnotherRunnerGroupIsNotAMatch() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName, runnerGroupID: 7)

      let missing = try await harness.client.getScaleSet(
        scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
      )
      #expect(missing == nil)
    }
  }

  @Test func deletesAScaleSetAndToleratesAnAbsentOne() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      try await harness.client.deleteScaleSet(scope: harness.scope, id: id)
      #expect(harness.service.scaleSetNames.isEmpty)
      // Idempotent: the reconciler runs again after the scale set is already gone.
      try await harness.client.deleteScaleSet(scope: harness.scope, id: id)
    }
  }

  @Test func resolvesARunnerGroupByName() async throws {
    try await withScaleSetHarness { harness in
      harness.service.addRunnerGroup(id: 7, name: "macs")
      let id = try await harness.client.runnerGroupID(scope: harness.scope, name: "macs")
      #expect(id == 7)

      let unknown = await captureError {
        _ = try await harness.client.runnerGroupID(scope: harness.scope, name: "nope")
      }
      let failure = try #require(unknown)
      #expect(errorClass(of: failure) == .notFound)
    }
  }

  // MARK: - Runners

  @Test func generatesAScaleSetJITConfigAndKeepsItOutOfDescriptions() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)

      let config = try await harness.client.generateJITConfig(
        scope: harness.scope, scaleSetID: id, runnerName: "runnervm-abc", workFolder: "_work"
      )

      #expect(config.runnerName == "runnervm-abc")
      #expect(!config.encodedJITConfig.isEmpty)
      // The secret must never appear in a log line or an error (spec §36).
      #expect(!config.description.contains(config.encodedJITConfig))
      #expect(config.description.contains("redacted"))
      #expect(harness.service.runnerIDs == [config.runnerID])

      let request = try #require(
        harness.service.requests("POST", containing: "generatejitconfig").first
      )
      #expect(request.bodyValue("name") as? String == "runnervm-abc")
      #expect(request.bodyValue("workFolder") as? String == "_work")
    }
  }

  @Test func looksUpARunnerByIDAndByName() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      let config = try await harness.client.generateJITConfig(
        scope: harness.scope, scaleSetID: id, runnerName: "runnervm-abc", workFolder: "_work"
      )

      let byID = try #require(await harness.client.runner(scope: harness.scope, id: config.runnerID))
      #expect(byID.name == "runnervm-abc")
      #expect(byID.runnerScaleSetId == id)

      let byName = try #require(
        await harness.client.runner(scope: harness.scope, name: "runnervm-abc")
      )
      #expect(byName.id == config.runnerID)
      #expect(try await harness.client.runner(scope: harness.scope, name: "ghost") == nil)
      #expect(try await harness.client.runner(scope: harness.scope, id: 999_999) == nil)
    }
  }

  @Test func runnerRemovalIsIdempotent() async throws {
    try await withScaleSetHarness { harness in
      let id = harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      let config = try await harness.client.generateJITConfig(
        scope: harness.scope, scaleSetID: id, runnerName: "runnervm-abc", workFolder: "_work"
      )

      try await harness.client.ensureRunnerRemoved(scope: harness.scope, runnerID: config.runnerID)
      #expect(harness.service.runnerIDs.isEmpty)
      // A scale-set runner deletes itself after one job, so teardown routinely 404s.
      try await harness.client.ensureRunnerRemoved(scope: harness.scope, runnerID: config.runnerID)
    }
  }

  // MARK: - Error classification (spec §52)

  @Test func classifiesActionsServiceFailures() async throws {
    let cases: [(Int, GitHubErrorClass)] = [
      (401, .authentication), (403, .authorization), (404, .notFound), (409, .conflict),
      (422, .permanentConfiguration), (500, .transientServer),
    ]
    for (status, expected) in cases {
      try await withScaleSetHarness(
        policy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero, jitter: 0)
      ) { harness in
        harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
        harness.service.failNext(
          containing: "runnerscalesets", method: "GET", status: status, times: 10
        )

        let error = await captureError {
          _ = try await harness.client.getScaleSet(
            scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
          )
        }
        let failure = try #require(error)
        #expect(errorClass(of: failure) == expected, "status \(status)")
      }
    }
  }

  @Test func retriesATransientFailureOnAnIdempotentRead() async throws {
    try await withScaleSetHarness { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      harness.service.failNext(containing: "runnerscalesets", method: "GET", status: 500)

      let info = try await harness.client.getScaleSet(
        scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
      )
      #expect(info?.name == ScaleSetFixture.scaleSetName)
      #expect(harness.sleeps.durations.count == 1)
    }
  }

  /// Creating a scale set is not idempotent: a retry would leave a duplicate behind.
  @Test func doesNotRetryScaleSetCreation() async throws {
    try await withScaleSetHarness { harness in
      harness.service.failNext(
        containing: "runnerscalesets", method: "POST", status: 500, times: 10
      )

      let error = await captureError {
        _ = try await harness.client.ensureScaleSet(
          scope: harness.scope, name: ScaleSetFixture.scaleSetName, runnerGroupID: 1, labels: [],
          disableUpdate: false
        )
      }
      let failure = try #require(error)
      #expect(errorClass(of: failure) == .transientServer)
      #expect(harness.service.requests("POST", containing: "runnerscalesets").count == 1)
    }
  }

  @Test func surfacesTheActionsExceptionInTheErrorMessage() async throws {
    try await withScaleSetHarness(
      policy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero, jitter: 0)
    ) { harness in
      harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
      harness.service.failNext(
        containing: "runnerscalesets", method: "GET", status: 403, message: "no access"
      )

      let error = await captureError {
        _ = try await harness.client.getScaleSet(
          scope: harness.scope, runnerGroupID: 1, name: ScaleSetFixture.scaleSetName
        )
      }
      let message = try #require(error as? GitHubControlError).message
      #expect(message.contains("ScriptedException"))
      #expect(message.contains("no access"))
    }
  }
}
