import DaemonAPI
import Foundation
import GuestControl
import RunnerCore

/// Exactly the `DaemonClient` calls `SmokeTest` needs, and nothing else. `DaemonClient` is a
/// concrete actor (`Sources/DaemonAPI/DaemonClient.swift`), so this protocol is the seam:
/// `SmokeTest` depends on it, `DaemonClient` conforms via the empty extension below (every method
/// it declares already matches one of `DaemonClient`'s own), and tests script a fake instead of
/// standing up a real daemon and a real VM.
public protocol SmokeTestDaemon: Sendable {
  /// `purpose` is always `InstancePurpose.maintenance.rawValue` at the call site: a smoke test
  /// only ever creates a pinned instance, never a plain runner one.
  func instanceCreate(
    profile: String, purpose: String?, ttlMs: Int64?, imageOverride: String?
  ) async throws -> InstanceInfoDTO

  func instanceGet(id: String) async throws -> InstanceInfoDTO

  /// Declared `async` (unlike `DaemonClient`'s own `nonisolated` synchronous version) because a
  /// synchronous throwing function can satisfy an `async throws` protocol requirement but not the
  /// other way around -- this is the one signature where the protocol and the concrete method
  /// differ, on purpose, so a fake implementation is free to be an ordinary actor method.
  func instanceExec(
    _ request: InstanceExecRequest
  ) async throws -> AsyncThrowingStream<InstanceExecEvent, any Error>

  func instanceSelfTest(id: String) async throws -> SelfTestResult

  func instanceSSHInfo(id: String) async throws -> InstanceSSHInfo

  func instanceDelete(id: String) async throws -> InstanceInfoDTO
}

extension DaemonClient: SmokeTestDaemon {}

/// Opens an existential daemon into `SmokeTest`'s generic parameter (SE-0352 implicit opening).
/// `HostInstaller` holds `any SetupDaemon`; `SmokeTest` is generic because dispatching the async
/// actor calls through an `any` existential aborted the Swift task allocator at runtime on a live
/// daemon (see the note on `SmokeTest`).
public func runSmokeTest(
  client: some SmokeTestDaemon, paths: RunnerPaths, options: SmokeTestOptions
) async -> SmokeTestReport {
  await SmokeTest(client: client, paths: paths).run(options)
}
