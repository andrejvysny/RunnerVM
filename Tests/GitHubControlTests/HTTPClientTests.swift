import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

struct GitHubHTTPClientTests {
  // MARK: - Request shape

  @Test func sendsAuthorizationAndAPIVersionHeaders() async throws {
    try await withHarness { harness in
      harness.server.stub(.get, "/user", .json("{\"login\":\"octocat\"}"))
      try #expect(try await harness.api.whoAmI() == "octocat")

      let recorded = try #require(harness.server.recorded.first)
      #expect(recorded.header("Authorization") == "Bearer \(Fixture.token)")
      #expect(recorded.header("Accept") == "application/vnd.github+json")
      #expect(recorded.header("X-GitHub-Api-Version") == GitHubControlModule.apiVersion)
      #expect(recorded.header("User-Agent") == "RunnerVM")
    }
  }

  // MARK: - Classification (spec §52)

  struct ClassificationCase {
    let status: Int
    let headers: [String: String]
    let expected: GitHubErrorClass
  }

  static let classifications: [ClassificationCase] = [
    ClassificationCase(status: 401, headers: [:], expected: .authentication),
    ClassificationCase(status: 403, headers: [:], expected: .authorization),
    ClassificationCase(status: 403, headers: ["Retry-After": "2"], expected: .rateLimited),
    ClassificationCase(
      status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000005"],
      expected: .rateLimited
    ),
    ClassificationCase(status: 404, headers: [:], expected: .notFound),
    ClassificationCase(status: 409, headers: [:], expected: .conflict),
    ClassificationCase(status: 422, headers: [:], expected: .permanentConfiguration),
    ClassificationCase(status: 429, headers: [:], expected: .rateLimited),
    ClassificationCase(status: 500, headers: [:], expected: .transientServer),
    ClassificationCase(status: 503, headers: [:], expected: .transientServer),
  ]

  @Test(arguments: classifications)
  func classifiesHTTPStatus(testCase: ClassificationCase) async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/user", .error(testCase.status, message: "nope", headers: testCase.headers)
      )
      let error = await captureError { _ = try await harness.api.whoAmI() }
      try #expect(try errorClass(of: #require(error)) == testCase.expected)
    }
  }

  @Test func classifiesTransportFailureAndBadJSON() async throws {
    try await withHarness { harness in
      harness.server.stub(.get, "/user", .failure(.timedOut))
      let transport = await captureError { _ = try await harness.api.whoAmI() }
      try #expect(try errorClass(of: #require(transport)) == .transport)

      harness.server.stub(.get, "/user", .json("{\"login\": "))
      let invalid = await captureError { _ = try await harness.api.whoAmI() }
      try #expect(try errorClass(of: #require(invalid)) == .invalidResponse)
    }
  }

  @Test func errorCarriesGitHubRequestID() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/user",
        .error(404, message: "Not Found", headers: ["X-GitHub-Request-Id": "ABCD:1234"])
      )
      let error = try #require(await captureError { _ = try await harness.api.whoAmI() })
      #expect((error as? GitHubControlError)?.message.contains("ABCD:1234") == true)
    }
  }

  // MARK: - Retry (spec §52)

  /// One observation per HTTP attempt, classified the way the error mapper classifies it, so
  /// `runnervm_github_requests_total{class}` counts retries and rate limits as they happen.
  @Test func reportsEveryAttemptToTheObserver() async throws {
    let observer = RecordingRequestObserver()
    try await withHarness(observer: observer) { harness in
      harness.server.stub(.get, "/user", .error(500), .json("{\"login\":\"octocat\"}"))
      _ = try await harness.api.whoAmI()
      harness.server.stub(.get, "/user", .failure(.timedOut))
      _ = await captureError { _ = try await harness.api.whoAmI() }
      harness.server.stub(.get, "/user", .json("{\"login\": "))
      _ = await captureError { _ = try await harness.api.whoAmI() }
      harness.server.stub(.get, "/user", .error(404))
      _ = await captureError { _ = try await harness.api.whoAmI() }
    }
    let outcomes = observer.outcomes
    #expect(outcomes.prefix(2) == [.serverError, .success])
    #expect(outcomes.contains(.transport))
    #expect(outcomes.contains(.decode))
    #expect(outcomes.last == .clientError)
  }

  @Test func retriesTransientServerErrorForIdempotentGET() async throws {
    try await withHarness { harness in
      harness.server.stub(.get, "/user", .error(500), .json("{\"login\":\"octocat\"}"))
      try #expect(try await harness.api.whoAmI() == "octocat")
      #expect(harness.server.requests(.get, "/user").count == 2)
      #expect(harness.sleeps.durations == [.seconds(1)])
    }
  }

  @Test func doesNotRetryNonIdempotentPost() async throws {
    try await withHarness { harness in
      let path = Fixture.repositoryScope.jitConfigPath
      harness.server.stub(.post, path, .error(500), .json("{}"))
      let error = await captureError {
        _ = try await harness.api.generateJITConfig(
          scope: Fixture.repositoryScope,
          request: JITRunnerRequest(name: "runnervm-1", labels: ["self-hosted"])
        )
      }
      try #expect(try errorClass(of: #require(error)) == .transientServer)
      #expect(harness.server.requests(.post, path).count == 1)
      #expect(harness.sleeps.durations.isEmpty)
    }
  }

  @Test func honorsRetryAfterHeader() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/user", .error(429, headers: ["Retry-After": "2"]), .json("{\"login\":\"octocat\"}")
      )
      try #expect(try await harness.api.whoAmI() == "octocat")
      #expect(harness.sleeps.durations == [.seconds(2)])
    }
  }

  @Test func honorsRateLimitResetWhenNoRetryAfter() async throws {
    try await withHarness { harness in
      harness.server.stub(
        .get, "/user",
        .error(
          403, message: "API rate limit exceeded",
          headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000005"]
        ),
        .json("{\"login\":\"octocat\"}")
      )
      try #expect(try await harness.api.whoAmI() == "octocat")
      #expect(harness.sleeps.durations == [.seconds(5)])
    }
  }

  @Test func exhaustedAttemptsSurfaceARetryableError() async throws {
    try await withHarness { harness in
      harness.server.stub(.get, "/user", .error(503))
      let error = try #require(await captureError { _ = try await harness.api.whoAmI() })
      #expect((error as? GitHubControlError)?.retryable == true)
      #expect(harness.server.requests(.get, "/user").count == Fixture.policy.maxAttempts)
      #expect(harness.sleeps.durations == [.seconds(1), .seconds(2)])
    }
  }

  @Test func doesNotSleepThroughALongRateLimit() async throws {
    try await withHarness(maxRetryAfter: .seconds(60)) { harness in
      harness.server.stub(.get, "/user", .error(429, headers: ["Retry-After": "3600"]))
      let error = try #require(await captureError { _ = try await harness.api.whoAmI() })
      #expect(errorClass(of: error) == .rateLimited)
      #expect((error as? GitHubControlError)?.retryAfter == .seconds(3600))
      #expect(harness.server.requests(.get, "/user").count == 1)
      #expect(harness.sleeps.durations.isEmpty)
    }
  }

  // MARK: - Pagination

  @Test func followsLinkHeaderToTheNextPage() async throws {
    try await withHarness { harness in
      let path = GitHubScope.runnerGroupsPath(org: "acme")
      let next = harness.server.baseURL.appending(path: path).appending(
        queryItems: [URLQueryItem(name: "page", value: "2")]
      )
      harness.server.stub(
        .get, path,
        .json(
          "{\"total_count\":3,\"runner_groups\":[{\"id\":1,\"name\":\"Default\"},{\"id\":2,\"name\":\"macOS\"}]}",
          headers: ["Link": "<\(next.absoluteString)>; rel=\"next\", <\(next.absoluteString)>; rel=\"last\""]
        ),
        .json("{\"total_count\":3,\"runner_groups\":[{\"id\":3,\"name\":\"gpu\"}]}")
      )

      let groups = try await harness.api.runnerGroups(org: "acme")
      #expect(groups.map(\.name) == ["Default", "macOS", "gpu"])
      #expect(harness.server.requests(.get, path).count == 2)
      #expect(harness.server.recorded.first?.query["per_page"] == "100")
      #expect(harness.server.recorded.last?.query["page"] == "2")
    }
  }
}
