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
