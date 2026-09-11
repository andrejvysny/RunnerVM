import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

/// The two things `FakeActionsService` cannot express, driven through the real
/// `ActionsServiceConnection` over a scripted `FakeGitHubServer` instead: a request that stalls
/// (the fake service answers instantly), and a runner listing the service is free to return but
/// the fake never would (its own `agentName` filter is exact).
struct ActionsServiceConnectionTests {
  /// The shared token exchange is deliberately unstructured: several sessions and every JIT call in
  /// a scope wait on the same one. A caller that gives up therefore has to take *itself* out of the
  /// queue -- `Task.value` cannot, which is what made `timeouts.jitGeneration` unenforceable on
  /// this path -- and must leave the exchange, and the token it produces, for everyone else.
  @Test func aCancelledCallerLeavesTheSharedTokenExchangeRunning() async throws {
    try await withExchangeHarness(
      registrationToken: .json("{\"token\":\"registration-token-1\"}", delay: .seconds(1))
    ) { harness in
      harness.server.stub(.get, ActionsEndpoint.runners, .json("{\"count\":0,\"value\":[]}"))
      let client = harness.client
      let scope = harness.scope
      let parked = Task { try await client.runner(scope: scope, name: "rvm-abc") }

      try await waitForCondition("the token exchange to be in flight") {
        !harness.server.requests(.post, harness.registrationTokenPath).isEmpty
      }
      parked.cancel()

      do {
        _ = try await parked.value
        Issue.record("the cancelled caller should not have been handed an answer")
      } catch is CancellationError {
      } catch {
        Issue.record("expected CancellationError, got \(error)")
      }
      // Load-bearing, and deliberately an ordering rather than a stopwatch: a waiter merely *left*
      // on `Task.value` also ends up throwing, but only once the whole exchange has finished, which
      // is after its second leg. Seeing no second leg yet is what says this caller took itself out
      // of the queue instead of waiting for GitHub like the bug this replaced.
      #expect(harness.server.requests(.post, ExchangeHarness.exchangePath).isEmpty)

      // And the exchange kept running: its second leg is reached once the first one answers, a
      // whole second after the caller that started it had already given up.
      try await waitForCondition("the shared exchange to finish anyway") {
        !harness.server.requests(.post, ExchangeHarness.exchangePath).isEmpty
      }
      // And its result was cached, so the next caller pays for no exchange at all.
      try #expect(await harness.client.runner(scope: scope, name: "rvm-abc") == nil)
      #expect(harness.server.requests(.post, harness.registrationTokenPath).count == 1)
      #expect(harness.server.requests(.post, ExchangeHarness.exchangePath).count == 1)
    }
  }

  /// `agentName` is the service's filter, not a contract, exactly as `?name=` is on the REST side
  /// (`GitHubActionsControlPlane.findRunner`). Whatever this returns gets DELETEd by recovery, so a
  /// prefix match must not be mistaken for the runner that was asked for.
  @Test func aNearMissOnTheAgentNameIsNotTheRunnerThatWasAskedFor() async throws {
    try await withExchangeHarness { harness in
      harness.server.stub(
        .get, ActionsEndpoint.runners,
        .json("{\"count\":1,\"value\":[{\"id\":7,\"name\":\"rvm-abcd\",\"runnerScaleSetId\":1}]}"))

      try #expect(await harness.client.runner(scope: harness.scope, name: "rvm-abc") == nil)

      // And a listing carrying both is not "two runners named rvm-abc" either.
      harness.server.stub(
        .get, ActionsEndpoint.runners,
        .json("""
          {"count":2,"value":[{"id":7,"name":"rvm-abcd","runnerScaleSetId":1},\
          {"id":8,"name":"rvm-abc","runnerScaleSetId":1}]}
          """))

      let found = try #require(
        try await harness.client.runner(scope: harness.scope, name: "rvm-abc"))
      #expect(found.id == 8)
      #expect(found.name == "rvm-abc")
    }
  }
}

private struct ExchangeHarness {
  let server: FakeGitHubServer
  let client: ActionsScaleSetClient
  let scope = Fixture.repositoryScope

  /// The REST leg of the exchange; the tenant leg is the same for every scope.
  var registrationTokenPath: String { scope.runnersPath + "/registration-token" }
  static let exchangePath = "/actions/runner-registration"
}

/// A real `ActionsScaleSetClient` whose REST leg, tenant exchange and tenant calls all land on one
/// `FakeGitHubServer`. The admin connection points back at the same host with no path prefix, so a
/// tenant endpoint is served at exactly its own path.
private func withExchangeHarness(
  registrationToken: FakeGitHubServer.Reply? = nil,
  _ body: (ExchangeHarness) async throws -> Void
) async throws {
  let server = FakeGitHubServer()
  defer { server.shutdown() }
  let scope = Fixture.repositoryScope
  server.stub(
    .post, scope.runnersPath + "/registration-token",
    registrationToken ?? .json("{\"token\":\"registration-token-1\"}"))
  server.stub(
    .post, ExchangeHarness.exchangePath,
    .json("{\"url\":\"\(server.baseURL.absoluteString)\",\"token\":\"\(adminJWT())\"}"))
  // One attempt everywhere: these cases are about what happens to a single call, not about the
  // retry ladder, and a retried stall would multiply the wall-clock cost of the test.
  let single = RetryPolicy(maxAttempts: 1)
  let http = GitHubHTTPClient(
    baseURL: server.baseURL, credentials: StaticCredentialProvider(token: Fixture.token),
    session: server.makeSession(), options: GitHubHTTPClient.Options(retryPolicy: single))
  let client = ActionsScaleSetClient(
    http: http, apiBaseURL: server.baseURL, configBaseURL: server.baseURL,
    session: server.makeSession(),
    options: ActionsServiceOptions(retryPolicy: single))
  try await body(ExchangeHarness(server: server, client: client))
}

/// `header.payload.signature`, base64url — only the `exp` claim is ever read (`ActionsJWT.expiry`).
private func adminJWT(expiresIn: TimeInterval = 3_600) -> String {
  let expiry = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
  return [base64URL("{\"alg\":\"none\"}"), base64URL("{\"exp\":\(expiry)}"), "signature"]
    .joined(separator: ".")
}

private func base64URL(_ text: String) -> String {
  Data(text.utf8).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private struct ConditionTimeout: Error, CustomStringConvertible {
  let description: String
}

/// Bounded poll for something only a fake can report (a request having arrived). Throwing rather
/// than recording stops the test here instead of piling follow-on failures on a stale state.
private func waitForCondition(
  _ description: String, attempts: Int = 400, interval: Duration = .milliseconds(10),
  _ condition: @Sendable () async throws -> Bool
) async throws {
  for _ in 0 ..< attempts {
    if try await condition() { return }
    try await Task.sleep(for: interval)
  }
  throw ConditionTimeout(description: "timed out waiting for \(description)")
}
