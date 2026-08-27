import RunnerCore

/// The points in the build ladder a fault-injection test can freeze the builder at.
///
/// One case per place where a daemon crash leaves a materially different amount of state behind:
/// nothing at all (`queued`), a pinned base (`resolvingBase`), a materialized VM directory
/// (`staging`), a live vmworker (`bootingGuest` onwards), sealed content the `images` row does not
/// know about yet (`storeCommit`), or a finished build whose push never started (`pushing`).
public enum BuildPhase: String, Sendable, CaseIterable {
  /// The row exists and the task has begun; nothing has been resolved yet.
  case queued
  /// Before the `FROM` base is resolved, fetched and pinned.
  case resolvingBase
  /// Before the build directory is cloned from that base and seeded.
  case staging
  /// Before `vmworker` is spawned, so no `worker.lock` holder exists yet.
  case launchingWorker
  /// After the worker answered `worker.hello`, before `vm.start`.
  case bootingGuest
  /// After `vm.start`, before the guest agent is reachable.
  case guestBootstrap
  /// Before each `RUN` step.
  case provisioningRun
  /// Before each `COPY` step.
  case provisioningCopy
  /// Before the readiness gate, the probe and the in-guest seal script.
  case sealing
  /// Before the sealed disk is hashed into the content-addressed store and registered.
  case storeCommit
  /// After the build is terminal and released, before the separate `push-image` operation starts.
  case pushing
}

/// Test-only seams into the build ladder.
///
/// Production never sets one: `DaemonRuntime` builds a default `Tuning`, so every hook is `nil` and
/// the ladder costs one optional check per phase and behaves exactly as it did without them.
public struct BuildHooks: Sendable {
  /// Awaited immediately before the named phase runs. A hook that never returns models a daemon
  /// that died at exactly that point -- the task stops there, and everything it already created
  /// (the pin, the directory, the vmworker) stays exactly as it was.
  public var beforePhase: (@Sendable (BuildPhase, ImageBuildID) async -> Void)?

  public init() {}
}
