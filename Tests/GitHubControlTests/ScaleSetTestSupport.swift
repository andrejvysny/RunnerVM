import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

struct ScaleSetHarness {
  let service: FakeActionsService
  let client: ActionsScaleSetClient
  let sleeps: SleepLog
  let scope = Fixture.organizationScope
}

/// A scale-set client bound to the in-process fake Actions service: no sockets, no sleeping, no
/// randomness. The same `URLSession` serves both the REST and the Actions-service host, exactly as
/// production wiring does.
func withScaleSetHarness(
  policy: RetryPolicy = Fixture.policy,
  options: ActionsServiceOptions? = nil,
  _ body: (ScaleSetHarness) async throws -> Void
) async throws {
  let service = FakeActionsService()
  defer { service.shutdown() }
  let session = service.makeSession()
  let sleeps = SleepLog()
  let http = GitHubHTTPClient(
    baseURL: service.restBaseURL,
    credentials: StaticCredentialProvider(token: Fixture.token),
    session: session,
    options: GitHubHTTPClient.Options(retryPolicy: policy),
    sleep: { sleeps.record($0) },
    random: { _ in 1.0 }
  )
  let client = ActionsScaleSetClient(
    http: http,
    apiBaseURL: service.restBaseURL,
    configBaseURL: service.configBaseURL,
    session: session,
    systemInfo: ScaleSetFixture.systemInfo,
    options: options ?? ActionsServiceOptions(retryPolicy: policy),
    sleep: { sleeps.record($0) },
    random: { _ in 1.0 }
  )
  try await body(ScaleSetHarness(service: service, client: client, sleeps: sleeps))
}

enum ScaleSetFixture {
  static let systemInfo = ActionsSystemInfo(
    system: "runnervm", version: "test-version", commitSHA: "test-sha", scaleSetID: 1,
    subsystem: "runnerd"
  )

  static let scaleSetName = "mac-arm64"

  /// The four job-message kinds, with the field sets the Actions service really sends for each.
  static let jobAvailable = """
  {"messageType":"JobAvailable","runnerRequestId":101,"repositoryName":"project-a",\
  "ownerName":"acme","jobId":"job-1","jobWorkflowRef":"acme/project-a/.github/workflows/ci.yml@refs/heads/main",\
  "jobDisplayName":"build","workflowRunId":9001,"eventName":"push","requestLabels":["mac-arm64"],\
  "queueTime":"2026-08-25T10:00:00Z","acquireJobUrl":"https://actions.invalid/acquire/101"}
  """

  static let jobAssigned = """
  {"messageType":"JobAssigned","runnerRequestId":102,"repositoryName":"project-a",\
  "ownerName":"acme","jobId":"job-2","queueTime":"2026-08-25T10:00:01Z",\
  "scaleSetAssignTime":"2026-08-25T10:00:02.5Z"}
  """

  static let jobStarted = """
  {"messageType":"JobStarted","runnerRequestId":103,"runnerId":42,"runnerName":"runnervm-abc",\
  "runnerAssignTime":"2026-08-25T10:00:03Z","ownerName":"acme","repositoryName":"project-a"}
  """

  static let jobCompleted = """
  {"messageType":"JobCompleted","runnerRequestId":104,"result":"succeeded","runnerId":43,\
  "runnerName":"runnervm-def","finishTime":"2026-08-25T10:05:00Z","ownerName":"acme",\
  "repositoryName":"project-a"}
  """

  static let allJobMessages = [jobAvailable, jobAssigned, jobStarted, jobCompleted]

  static let busyStatistics = ScaleSetStatistics(
    totalAvailableJobs: 1, totalAcquiredJobs: 2, totalAssignedJobs: 3, totalRunningJobs: 4,
    totalRegisteredRunners: 5, totalBusyRunners: 6, totalIdleRunners: 7
  )
}

/// Opens a session against a freshly created scale set.
func withOpenSession(
  policy: RetryPolicy = Fixture.policy,
  _ body: (ScaleSetHarness, Int64, any ScaleSetSession) async throws -> Void
) async throws {
  try await withScaleSetHarness(policy: policy) { harness in
    let scaleSetID = harness.service.seedScaleSet(name: ScaleSetFixture.scaleSetName)
    let session = try await harness.client.openSession(
      scope: harness.scope, scaleSetID: scaleSetID, owner: "acme"
    )
    try await body(harness, scaleSetID, session)
  }
}
