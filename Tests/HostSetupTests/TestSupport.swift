import ConfigLoader
import DaemonAPI
import Foundation
import GuestControl
import RunnerCore

@testable import HostSetup

extension InstanceInfoDTO {
  static func stub(
    id: String = "11111111-2222-3333-4444-555555555555", state: String = "idle",
    failureCode: String? = nil, failureMessage: String? = nil
  ) -> InstanceInfoDTO {
    InstanceInfoDTO(
      id: id, name: "rvm-test-\(id.prefix(8))", profile: "ubuntu-24", imageDigest: "sha256:abc",
      state: state, workerGeneration: 1, cpuCount: 2, memoryBytes: 4_294_967_296,
      diskBytes: 21_474_836_480, diskReservationBytes: 21_474_836_480,
      createdAt: "2026-01-01T00:00:00.000Z", failureCode: failureCode,
      failureMessage: failureMessage, purpose: InstancePurpose.maintenance.rawValue)
  }
}

/// A fake `SmokeTestDaemon` scripted per test: fixed answers for create/selfTest/sshInfo/exec, a
/// list of instance states `instanceGet` walks through (repeating the last one), and a flag that
/// flips once `instanceDelete` is called so the leak poll sees `deleted` without needing a script
/// of its own.
actor FakeSmokeTestDaemon: SmokeTestDaemon {
  enum Scripted<T: Sendable>: Sendable {
    case value(T)
    case failure(any Error)

    func get() throws -> T {
      switch self {
      case .value(let value): return value
      case .failure(let error): throw error
      }
    }
  }

  var createResult: Scripted<InstanceInfoDTO>
  var bootStates: [String]
  var execResult: Scripted<(output: String, exitCode: Int32)>
  var selfTestResult: Scripted<SelfTestResult>
  var sshInfoResult: Scripted<InstanceSSHInfo>
  var deleteResult: Scripted<Void>

  private(set) var getCallCount = 0
  private(set) var deleteCallCount = 0
  private var deleted = false

  init(
    createResult: Scripted<InstanceInfoDTO> = .value(.stub()),
    bootStates: [String] = ["idle"],
    execResult: Scripted<(output: String, exitCode: Int32)> = .value(("ok", 0)),
    selfTestResult: Scripted<SelfTestResult> = .value(SelfTestResult()),
    sshInfoResult: Scripted<InstanceSSHInfo> = .value(
      InstanceSSHInfo(ipAddresses: [], user: "runner", sshEnabled: true)),
    deleteResult: Scripted<Void> = .value(())
  ) {
    self.createResult = createResult
    self.bootStates = bootStates
    self.execResult = execResult
    self.selfTestResult = selfTestResult
    self.sshInfoResult = sshInfoResult
    self.deleteResult = deleteResult
  }

  func instanceCreate(
    profile: String, purpose: String?, ttlMs: Int64?, imageOverride: String?
  ) async throws -> InstanceInfoDTO {
    try createResult.get()
  }

  func instanceGet(id: String) async throws -> InstanceInfoDTO {
    getCallCount += 1
    if deleted { return .stub(id: id, state: "deleted") }
    let index = min(getCallCount - 1, bootStates.count - 1)
    return .stub(id: id, state: bootStates[index])
  }

  func instanceExec(
    _ request: InstanceExecRequest
  ) async throws -> AsyncThrowingStream<InstanceExecEvent, any Error> {
    let (output, exitCode) = try execResult.get()
    return AsyncThrowingStream { continuation in
      continuation.yield(.chunk(InstanceExecChunk(stream: "stdout", data: Data(output.utf8))))
      continuation.yield(.exited(exitCode))
      continuation.finish()
    }
  }

  func instanceSelfTest(id: String) async throws -> SelfTestResult { try selfTestResult.get() }

  func instanceSSHInfo(id: String) async throws -> InstanceSSHInfo { try sshInfoResult.get() }

  func instanceDelete(id: String) async throws -> InstanceInfoDTO {
    deleteCallCount += 1
    try deleteResult.get()
    deleted = true
    return .stub(id: id, state: "deleted")
  }
}

struct TestError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A fake clock/sleeper pair for `SmokeTest`'s injectable `now`/`sleep`: `advance` moves the
/// clock forward exactly as far as `SmokeTest` asked it to sleep, so a boot-timeout test
/// terminates deterministically after N fake seconds rather than N real ones.
///
/// `@unchecked Sendable`: every test drives one `SmokeTest.run` at a time from a single `Task`, so
/// access is never actually concurrent -- the checked alternative (an actor) cannot back a
/// synchronous `now: @Sendable () -> Date` closure.
final class FakeClock: @unchecked Sendable {
  private var current: Date

  init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    self.current = start
  }

  func now() -> Date { current }

  func advance(by duration: Duration) {
    let parts = duration.components
    current = current.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }
}

// MARK: - Setup fixtures

extension SetupHostFacts {
  /// A base Mac mini M4: 10 logical CPUs, 24 GiB, 200 GiB free.
  static func stub(
    cpuCount: Int = 10,
    memoryBytes: UInt64 = ByteSize.gibibytes(24).bytes,
    freeDiskBytes: UInt64 = ByteSize.gibibytes(200).bytes,
    hostID6: String = "ab12cd",
    fileVault: FileVaultStatus = .off,
    existingInstall: ExistingInstall = ExistingInstall()
  ) -> SetupHostFacts {
    SetupHostFacts(
      model: "Mac16,10", cpuCount: cpuCount, memoryBytes: memoryBytes,
      freeDiskBytes: freeDiskBytes, macOSVersion: "26.5.2", isAppleSilicon: true,
      hostID6: hostID6, fileVault: fileVault, existingInstall: existingInstall)
  }
}

extension SetupAnswers {
  static func stub(
    scope: SetupScope = .repository(owner: "acme", repository: "widgets"),
    linuxEnabled: Bool = true,
    macOSEnabled: Bool = false,
    linuxConcurrency: Int = 2,
    token: String = "ghp_token"
  ) -> SetupAnswers {
    SetupAnswers(
      scope: scope, token: token, linuxEnabled: linuxEnabled, macOSEnabled: macOSEnabled,
      linuxConcurrency: linuxConcurrency,
      linuxProfileName: "rvm-ab12cd-ubuntu-24", macOSProfileName: "rvm-ab12cd-macos-tahoe")
  }
}

/// A `SetupDaemon` scripted per test. The `SmokeTestDaemon` half behaves like
/// `FakeSmokeTestDaemon`'s happy path — a smoke test is not what these tests are about — while
/// every setup-specific call can be made to fail independently.
actor FakeSetupDaemon: SetupDaemon {
  var authLoginResult: FakeSmokeTestDaemon.Scripted<AuthLoginResponse>
  var githubTestResult: FakeSmokeTestDaemon.Scripted<GitHubTestResponse>
  var imagePullResult: FakeSmokeTestDaemon.Scripted<ImagePullResponse>
  var operationStates: [String]
  var configApplyResult: FakeSmokeTestDaemon.Scripted<ConfigApplyResponse>
  var smokeTestPasses: Bool

  private(set) var calls: [String] = []
  private(set) var appliedYAML: String?
  private(set) var loggedInToken: String?
  private var operationCallCount = 0
  private var deleted = false

  init(
    authLoginResult: FakeSmokeTestDaemon.Scripted<AuthLoginResponse> = .value(
      AuthLoginResponse(location: "file /state/github-token", status: .stubHealthy())),
    githubTestResult: FakeSmokeTestDaemon.Scripted<GitHubTestResponse> = .value(.stubHealthy()),
    imagePullResult: FakeSmokeTestDaemon.Scripted<ImagePullResponse> = .value(
      ImagePullResponse(
        reference: "ghcr.io/andrejvysny/runnervm/ubuntu-24-base@sha256:abc",
        manifestDigest: "sha256:abc", operationId: "op-1", alreadyPresent: false, digest: nil)),
    operationStates: [String] = ["succeeded"],
    configApplyResult: FakeSmokeTestDaemon.Scripted<ConfigApplyResponse> = .value(
      ConfigApplyResponse(
        diff: ConfigDiff(addedProfiles: ["rvm-ab12cd-ubuntu-24"]), operationId: "op-2",
        issues: [], appliedAt: "2026-08-28T00:00:00.000Z")),
    smokeTestPasses: Bool = true
  ) {
    self.authLoginResult = authLoginResult
    self.githubTestResult = githubTestResult
    self.imagePullResult = imagePullResult
    self.operationStates = operationStates
    self.configApplyResult = configApplyResult
    self.smokeTestPasses = smokeTestPasses
  }

  func authLogin(token: String) async throws -> AuthLoginResponse {
    calls.append("authLogin")
    loggedInToken = token
    return try authLoginResult.get()
  }

  func githubTest() async throws -> GitHubTestResponse {
    calls.append("githubTest")
    return try githubTestResult.get()
  }

  func imagePull(reference: String, format _: String?) async throws -> ImagePullResponse {
    calls.append("imagePull(\(reference))")
    return try imagePullResult.get()
  }

  func operationGet(id: String) async throws -> OperationInfo {
    calls.append("operationGet")
    let index = min(operationCallCount, operationStates.count - 1)
    operationCallCount += 1
    let state = operationStates[index]
    return OperationInfo(
      id: id, kind: "pull-image", resourceType: "image", resourceId: "img", state: state,
      startedAt: "2026-08-28T00:00:00.000Z",
      errorCode: state == "failed" ? "IMAGE_PULL_FAILED" : nil,
      errorMessage: state == "failed" ? "registry unreachable" : nil)
  }

  func configApply(yaml: String) async throws -> ConfigApplyResponse {
    calls.append("configApply")
    appliedYAML = yaml
    return try configApplyResult.get()
  }

  // MARK: - SmokeTestDaemon

  func instanceCreate(
    profile _: String, purpose _: String?, ttlMs _: Int64?, imageOverride _: String?
  ) async throws -> InstanceInfoDTO {
    calls.append("instanceCreate")
    guard smokeTestPasses else { throw TestError("instance.create refused") }
    return .stub()
  }

  func instanceGet(id: String) async throws -> InstanceInfoDTO {
    .stub(id: id, state: deleted ? "deleted" : "idle")
  }

  func instanceExec(
    _: InstanceExecRequest
  ) async throws -> AsyncThrowingStream<InstanceExecEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.chunk(InstanceExecChunk(stream: "stdout", data: Data("Linux".utf8))))
      continuation.yield(.exited(0))
      continuation.finish()
    }
  }

  func instanceSelfTest(id _: String) async throws -> SelfTestResult { SelfTestResult() }

  func instanceSSHInfo(id _: String) async throws -> InstanceSSHInfo {
    InstanceSSHInfo(ipAddresses: [], user: "runner", sshEnabled: true)
  }

  func instanceDelete(id: String) async throws -> InstanceInfoDTO {
    deleted = true
    return .stub(id: id, state: "deleted")
  }
}

extension AuthStatus {
  static func stubHealthy() -> AuthStatus {
    AuthStatus(
      state: "healthy", provider: "pat", source: "file",
      location: "file /state/github-token", login: "acme-bot")
  }

  static func stubInvalid() -> AuthStatus {
    AuthStatus(
      state: "invalid", provider: "pat", source: "file", location: "file /state/github-token",
      problem: "GITHUB_UNAUTHORIZED: bad credentials",
      hint: "the token is expired or was revoked")
  }
}

extension GitHubTestResponse {
  static func stubHealthy() -> GitHubTestResponse {
    GitHubTestResponse(
      auth: .stubHealthy(),
      scopes: [ScopeHealthDTO(
        name: "repo", slug: "acme/widgets", kind: "repository", status: "healthy",
        schedulable: true)])
  }

  static func stubForbidden() -> GitHubTestResponse {
    GitHubTestResponse(
      auth: .stubInvalid(),
      scopes: [ScopeHealthDTO(
        name: "repo", slug: "acme/widgets", kind: "repository", status: "unhealthy",
        schedulable: false,
        problems: [ScopeProblemDTO(
          code: "GITHUB_FORBIDDEN", errorClass: "permission",
          detail: "the token cannot administer runners on acme/widgets")])])
  }
}
