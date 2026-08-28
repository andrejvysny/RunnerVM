import Foundation
import Logging
import Metrics
import Persistence
import RunnerCore
import RunnerLogging

/// What a `macosTart` track does once its upstream source digest has moved.
///
/// Phase D6 only *notices*: a Tart export carries no RunnerVM guest agent, so it can never be
/// promoted by pulling it -- it has to be provisioned into a new, locally sealed image first
/// (`docs/design/distribution.md`, "Managed image sources"). D7 supplies that launcher; until it
/// does, `ImageUpdateService` is constructed with `nil` here and the moved digest is recorded and
/// reported rather than acted on.
public protocol MacOSProvisionLauncher: Sendable {
  func provision(_ track: ManagedImageRecord) async
}

/// The image update cycle (`images.updates`, phase D6): resolve every tracked source, pull what
/// moved, qualify it, and promote it in one row write.
///
/// Wired like the maintenance loop -- one long-lived `Task` in `DaemonRuntime`, cancelled and
/// awaited at teardown -- and, like `ImageManager`, re-reads its policy on every `config.apply`
/// rather than snapshotting it at startup.
///
/// The invariants it exists to keep (`docs/design/distribution.md`, "Update invariants"):
/// a running VM is never terminated; a failure never replaces the working image;
/// `images.updates.keepPrevious` is the only deletion trigger, and only where `ImageManager`'s
/// prune eligibility also agrees; a profile pinned to an explicit `@sha256:…` is never tracked.
public actor ImageUpdateService {
  public struct Tuning: Sendable {
    /// How long after startup the first sweep runs. Deliberately not zero: daemon start is
    /// already resolving profile images, and a registry burst on top of it buys nothing.
    public var firstCycleDelay: Duration = .seconds(60)
    /// Ceiling on the boot-to-idle qualification gate.
    public var smokeTestTimeout: Duration = .seconds(240)
    public var smokeTestPollInterval: Duration = .milliseconds(500)
    /// `pinnedUntil` for the qualification VM. Comfortably past `smokeTestTimeout`, so the
    /// reaper is a backstop for a crashed daemon rather than a racer against this cycle.
    public var smokeTestTTL: Duration = .seconds(600)
    public var now: @Sendable () -> Date = { Date() }

    public init() {}
  }

  /// What a `macosTart` track reports while its source has moved and nothing can act on it yet.
  static let provisioningPending =
    "source changed; local macOS provisioning arrives in phase D7"

  let managed: any ManagedImageRepository
  let imageRows: any ImageRepository
  let images: ImageManager
  let instances: InstanceManager
  let instanceRows: any InstanceRepository
  /// `nil` on a daemon with no GitHub credential: every image then grades `unknown`, which is
  /// never `tooOld`, so qualification simply does not apply the freshness check.
  let runnerVersions: RunnerVersionMonitor?
  let provisioning: (any MacOSProvisionLauncher)?
  let metrics: MetricRegistry
  let tuning: Tuning
  let logger: Logger

  var configuration: RunnerConfiguration?
  /// One sweep at a time. The scheduled loop, `image.update.run` and `image.update.check` all ask
  /// for the same work, and a second concurrent pass would only race the first on the same rows.
  var cycleRunning = false
  /// The detached cycle `image.update.run` started, so teardown can cancel it instead of leaving
  /// a pull running against a daemon that is going away.
  var manualCycle: Task<Void, Never>?
  /// `recoverInterrupted` is a startup step, not a per-cycle one.
  var recovered = false

  public init(
    managed: any ManagedImageRepository, imageRows: any ImageRepository, images: ImageManager,
    instances: InstanceManager, instanceRows: any InstanceRepository,
    runnerVersions: RunnerVersionMonitor? = nil,
    provisioning: (any MacOSProvisionLauncher)? = nil, metrics: MetricRegistry = MetricRegistry(),
    tuning: Tuning = Tuning(), logger: Logger = Logger(component: .image)
  ) {
    self.managed = managed
    self.imageRows = imageRows
    self.images = images
    self.instances = instances
    self.instanceRows = instanceRows
    self.runnerVersions = runnerVersions
    self.provisioning = provisioning
    self.metrics = metrics
    self.tuning = tuning
    self.logger = logger
  }

  // MARK: - Configuration

  /// Adopts the applied document and re-derives the tracked set. Called at bootstrap and on every
  /// `config.apply`, exactly like `ImageManager.updateConfiguration`.
  ///
  /// Track bookkeeping happens whether or not `images.updates.enabled` is set: an operator has to
  /// be able to see what *would* be tracked, and turning updates on must not need a config
  /// round trip to populate the table.
  public func updateConfiguration(_ config: RunnerConfiguration?) async {
    configuration = config
    guard let config else { return }
    do {
      try await deriveTracks(config)
    } catch {
      logger.warning(
        "could not record managed image tracks",
        metadata: ["error": .string(Self.message(error))])
    }
  }

  /// `images.updates`, clamped to the bounds the configuration type documents: an interval below
  /// `minimumInterval` is pure registry traffic, and retaining more than `maximumKeepPrevious`
  /// whole disk images is a storage leak with a configuration key in front of it.
  var policy: ImageUpdatePolicyConfig {
    var value = configuration?.images.updates ?? ImageUpdatePolicyConfig()
    if value.interval < ImageUpdatePolicyConfig.minimumInterval {
      value.interval = ImageUpdatePolicyConfig.minimumInterval
    }
    value.keepPrevious = min(
      max(0, value.keepPrevious), ImageUpdatePolicyConfig.maximumKeepPrevious)
    return value
  }

  public func isEnabled() -> Bool { policy.enabled }

  public func firstCycleDelay() -> Duration { tuning.firstCycleDelay }

  /// `interval` ± `jitter`, so a fleet installed from one script does not check in lockstep.
  public func nextDelay() -> Duration {
    let value = policy
    let jitter = value.jitter.milliseconds
    guard jitter > 0 else { return value.interval.duration }
    let offset = Int64.random(in: -jitter...jitter)
    return .milliseconds(max(1, value.interval.milliseconds + offset))
  }

  // MARK: - Track derivation

  /// Every profile whose `image:` is a registry reference *with a tag*, plus every
  /// `images.managed[]` entry.
  ///
  /// The applied document is exactly the set of enabled profiles: `runner_profiles.enabled` goes
  /// to `false` precisely when a profile leaves the configuration (`ConfigApplier`), so a profile
  /// present here is one this host is meant to run.
  ///
  /// A digest-pinned profile is deliberately absent: the operator already said which bytes they
  /// want. So is a bare local name -- there is no upstream to re-resolve. A row whose source has
  /// disappeared from the configuration is left exactly as it is, state and all: deleting it would
  /// throw away the pins and the retention list that still describe images on this disk.
  func deriveTracks(_ config: RunnerConfiguration) async throws {
    for profile in config.profiles {
      guard let reference = Self.trackedReference(profile.image) else { continue }
      try await record(
        name: reference, kind: .registryTag, source: reference, autoUpdate: true)
    }
    for source in config.images.managed {
      try await record(
        name: source.name, kind: source.kind, source: source.source,
        autoUpdate: source.autoUpdate)
    }
  }

  /// The canonical form of a trackable profile image, or `nil` when the reference is not one.
  static func trackedReference(_ image: String) -> String? {
    guard let reference = try? ImageReference(parsing: image), reference.digest == nil,
          reference.tag != nil
    else { return nil }
    return reference.description
  }

  /// Insert, or refresh only the columns the configuration owns. Everything the cycle owns --
  /// state, digests, retention, timestamps -- survives untouched, which is what lets a daemon
  /// restart resume mid-track instead of starting the world over.
  private func record(
    name: String, kind: ManagedImageKind, source: String, autoUpdate: Bool
  ) async throws {
    guard var existing = try await managed.get(name: name) else {
      try await managed.upsert(
        ManagedImageRecord(
          name: name, kind: kind, sourceReference: source, autoUpdate: autoUpdate,
          updatedAt: .now))
      logger.info(
        "managed image tracked",
        metadata: ["managed": .string(name), "kind": .string(kind.rawValue),
                   "source": .string(source)])
      return
    }
    guard existing.kind != kind || existing.sourceReference != source
      || existing.autoUpdate != autoUpdate
    else { return }
    existing.kind = kind
    existing.sourceReference = source
    existing.autoUpdate = autoUpdate
    existing.updatedAt = .now
    try await managed.upsert(existing)
  }

  // MARK: - Entry points

  /// The scheduled sweep. A no-op when `images.updates.enabled` is off -- the manual RPCs still
  /// work, because an operator asking for one update is not the same as a host doing it by itself.
  public func runScheduledCycle() async {
    guard policy.enabled else { return }
    _ = await runCycle(only: nil, manual: false, resolveOnly: false)
  }

  /// `image.update.check`: resolve every tracked source (or one) and stop there.
  @discardableResult
  public func check(only name: String? = nil) async -> [ManagedImageRecord] {
    await runCycle(only: name, manual: true, resolveOnly: true)
  }

  /// `image.update.run`: starts a full cycle and returns immediately, the way `image.pull` answers
  /// before the transfer finishes. A pull plus a boot-to-idle qualification does not fit inside
  /// the socket's idle timeout.
  ///
  /// The tracks are moved to `checking` *before* this returns, so the snapshots the caller gets
  /// back already show the cycle as running. Without that, `runnerctl image update run --wait`
  /// could poll `image.update.status` before the detached task had reached the actor, see every
  /// track resting, and report a cycle that had not started as one that had finished.
  ///
  /// The reservation is also the lock: a scheduled sweep skips a row it finds mid-cycle, so no
  /// second pass can pick these tracks up.
  public func startCycle(only name: String? = nil) async -> [ManagedImageRecord] {
    let reserved = await reserve(only: name)
    guard !reserved.isEmpty else { return await snapshots() }
    // Not cancelling whatever is already there: a second `image.update.run` reserves nothing while
    // the first still owns the rows, so it cannot reach this line and abort that transfer.
    manualCycle = Task { [weak self] in await self?.runReserved(reserved) }
    return await snapshots()
  }

  /// Claims every resting track the request names, `idle`/`failed -> checking`, and hands back the
  /// rows as they now stand. A track another pass already owns is simply not claimed.
  private func reserve(only name: String?) async -> [ManagedImageRecord] {
    var reserved: [ManagedImageRecord] = []
    for track in await snapshots() where name == nil || track.name == name {
      guard track.state == .idle || track.state == .failed,
            let claimed = try? await managed.transition(
              name: track.name, from: track.state, to: .checking, mutate: { $0.lastError = nil })
      else { continue }
      reserved.append(claimed)
    }
    return reserved
  }

  private func runReserved(_ tracks: [ManagedImageRecord]) async {
    cycleRunning = true
    defer { cycleRunning = false }
    for track in tracks {
      guard !Task.isCancelled else {
        // Hand the claim back rather than stranding the row in `checking` for the next process to
        // find; a cancelled shutdown promoted nothing, so `idle` is the truth.
        _ = try? await managed.transition(name: track.name, from: .checking, to: .idle) { _ in }
        continue
      }
      await cycle(track, resolveOnly: false, reserved: true)
    }
  }

  /// Rows a previous process left mid-cycle.
  ///
  /// `ManagedImageState` has no edge back to `idle` from `downloading`/`qualifying`/`promoting`,
  /// and `cycle` refuses to race a row it does not own, so without this a daemon that died mid-pull
  /// would never touch that track again. `failed` is the honest landing state: nothing was
  /// promoted, and the next sweep retries from scratch. A crash between the candidate's `managed`
  /// pin and the promoting row write leaves that pin behind, which keeps the candidate's bytes
  /// around for the retry and is replaced by the next successful promotion.
  public func recoverInterrupted() async {
    guard !recovered else { return }
    recovered = true
    for track in await snapshots() where track.state != .idle && track.state != .failed {
      _ = try? await managed.transition(name: track.name, from: track.state, to: .failed) { row in
        row.candidateImageDigest = nil
        row.lastError = "interrupted by a daemon restart while \(track.state.rawValue)"
      }
      logger.notice(
        "managed image update was interrupted by a restart",
        metadata: ["managed": .string(track.name), "state": .string(track.state.rawValue)])
    }
  }

  /// The awaited form, for tests and for anything that needs the outcome rather than the kick.
  @discardableResult
  public func runCycle(
    only name: String? = nil, manual: Bool = true, resolveOnly: Bool = false
  ) async -> [ManagedImageRecord] {
    guard !cycleRunning else { return await snapshots() }
    cycleRunning = true
    defer { cycleRunning = false }
    let tracks = await snapshots()
    for track in tracks where name == nil || track.name == name {
      // `autoUpdate: false` means "not on your own", not "never": an operator naming the track
      // explicitly, or asking for a manual run, still gets one.
      guard manual || track.autoUpdate else { continue }
      guard !Task.isCancelled else { break }
      await cycle(track, resolveOnly: resolveOnly)
    }
    return await snapshots()
  }

  public func snapshots() async -> [ManagedImageRecord] {
    ((try? await managed.list()) ?? []).sorted { $0.name < $1.name }
  }

  public func track(named name: String) async -> ManagedImageRecord? {
    try? await managed.get(name: name)
  }

  /// Cancels an in-flight manual cycle. Called from `DaemonRuntime.teardown` alongside the loop.
  public func stop() async {
    manualCycle?.cancel()
    await manualCycle?.value
    manualCycle = nil
  }

  // MARK: - Helpers

  static func message(_ error: any Error) -> String {
    (error as? any RunnerError)?.message ?? String(describing: error)
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }

  func noteCheck(kind: ManagedImageKind) async {
    await metrics.increment(
      RunnerVMMetrics.imageUpdateChecksTotal,
      labels: [RunnerVMMetrics.kindLabel: kind.rawValue])
    await metrics.setGauge(
      RunnerVMMetrics.imageUpdateLastCheckTimestamp, to: tuning.now().timeIntervalSince1970)
  }
}
