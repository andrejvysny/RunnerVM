import Foundation
import ImageStore
import Logging
import Metrics
import OCIRegistry
import Persistence
import RunnerCore
import RunnerLogging

/// The one transfer several callers share, plus the operation row that tracks it (spec §137).
public struct InFlightPull: Sendable {
  /// Resolved separately from `task` because the operation row is a database write: the in-flight
  /// entry has to be published *synchronously*, before the first `await`, or two callers racing on
  /// the same digest would both miss it and start two transfers.
  let operation: Task<OperationID?, Never>
  let task: Task<ImageRecord, any Error>
}

/// What `image.pull` can report before any bytes have moved.
public struct ImagePullStart: Sendable, Hashable {
  /// `<registry>/<repository>@sha256:…` the reference resolved to (spec §21).
  public let reference: String
  /// The registry manifest digest — the identity concurrent pulls deduplicate on.
  public let manifestDigest: ImageDigest
  /// `nil` when the image was already in the store, so no transfer was started.
  public let operationId: OperationID?
  /// Local content digest; set only when the image was already present.
  public let localDigest: ImageDigest?
}

/// What `image.push` reports once the transfer is under way.
public struct ImagePushStart: Sendable, Hashable {
  /// The requested target reference, tag and all.
  public let reference: String
  /// Local content digest of the image being published.
  public let digest: ImageDigest
  public let operationId: OperationID?
}

/// What `image.inspectRemote` learns from a registry without moving a disk byte.
public struct RemoteImageDescription: Sendable {
  /// `<registry>/<repository>@sha256:…` — the immutable form to pin a profile at (spec §21).
  public let reference: OCIReference
  /// The registry manifest digest, which is not the local content digest: that one does not exist
  /// until the bytes do.
  public let manifestDigest: ImageDigest
  public let format: ImageArtifactFormat
  public let metadata: ImageMetadata
  /// Compressed bytes a pull would move.
  public let transferBytes: UInt64
}

/// Registry pull and push. Split out of `ImageManager.swift` to keep that file under its line
/// budget; every member below runs actor-isolated on `ImageManager` exactly as if declared there.
extension ImageManager {
  public static let pullOperationKind = "pull-image"
  public static let pushOperationKind = "push-image"
  /// Label used on `image_pull_seconds` when no profile drove the pull (an operator's
  /// `runnerctl image pull`), so the family still carries a dimension worth grouping by.
  public static let registryLabel = "registry"

  enum PullOutcome {
    case present(ImagePullStart, ImageRecord)
    /// The one transfer everyone sharing this digest is waiting on, and the reference it will land
    /// under. `start.operationId` is deliberately `nil`: resolving it means awaiting an unstructured
    /// `Task`, which only `startPull` -- the one caller with no deadline over it -- may do.
    case started(ImagePullStart, canonical: OCIReference, running: InFlightPull)
  }

  /// A shared transfer's own failure, rebuilt from its `pull-image` operation row for a caller that
  /// waited on it rather than started it.
  ///
  /// The row is the only place that outcome is written down (the transfer's `Task` belongs to
  /// whoever started it, and awaiting it is exactly what the deadline design forbids), so the class
  /// of failure -- `REGISTRY_AUTH`, `IMAGE_INSUFFICIENT_DISK_SPACE` -- is preserved rather than
  /// flattened into a bare `IMAGE_PULL_FAILED`. Retryable like `ImageError.pullFailed`, which is
  /// what the caller that *started* the same transfer gets: the row records no retryability, and a
  /// waiter must not be more permanent than the starter it was sharing with.
  struct SharedPullFailure: RunnerError {
    let code: String
    let message: String
    var retryable: Bool { true }
  }

  // MARK: - Resolution

  /// Local name/digest, or a registry reference resolved (and pulled when missing) per spec §21.
  ///
  /// `purpose` travels all the way into `inspect`, so a profile pointing at an agentless remote
  /// image is refused after its config blobs and before any disk transfer, operation row, staging
  /// directory or pin exists (spec §58).
  ///
  /// `timeout` bounds *this caller's* wait (a profile's `timeouts.imagePull`), never the transfer:
  /// `.zero` -- what every caller but `instance.create` passes -- waits as long as the pull takes.
  func resolveRecord(
    reference: String, profile: String?, purpose: ImagePullPurpose = .storage,
    timeout: DurationValue = .zero
  ) async throws -> ImageRecord {
    guard let ref = Self.registryReference(reference) else {
      return try await record(for: reference)
    }
    if let promoted = try await promotedRecord(ref) {
      return try await touch(promoted)
    }
    if let known = try await cachedRegistryRecord(ref) {
      return try await touch(known)
    }
    return try await boundedPull(ref, profile: profile, purpose: purpose, timeout: timeout)
  }

  /// Pulls under one caller's deadline (spec §73), leaving the transfer everyone shares untouched.
  ///
  /// Two phases, because only the first one is this caller's work to cancel. Resolution and
  /// inspection are raced against the deadline directly -- `RunnerVMImageTransfer.inspect` is
  /// `URLSession`'s async API all the way down, so cancelling it cancels a real request. The wait
  /// that follows cannot be: the transfer is an unstructured `Task` shared with every other caller
  /// on this digest, and awaiting its value would ignore cancellation and park the deadline's task
  /// group until the download finished (see `withDeadline`'s hard rule). So the second phase polls
  /// the in-flight map instead, and expiry leaves the transfer running for whoever else wants it.
  ///
  /// `ContinuousClock`, not `now`: the injected clock is frozen in tests and is a wall clock in
  /// production, neither of which can measure how much of the budget phase one spent.
  private func boundedPull(
    _ ref: OCIReference, profile: String?, purpose: ImagePullPurpose, timeout: DurationValue
  ) async throws -> ImageRecord {
    let startedAt = ContinuousClock.now
    let reference = ref.description
    let outcome = try await withDeadline(
      timeout, expired: { ImageError.pullTimeout(reference: reference) }
    ) {
      try await self.beginPull(
        reference: reference, profile: profile, progress: nil, purpose: purpose)
    }
    switch outcome {
    case let .present(_, record):
      return record
    case let .started(start, canonical, running):
      return try await awaitInFlightPull(
        digest: start.manifestDigest, canonical: canonical, mine: running.task,
        limit: timeout.isPositive ? startedAt.advanced(by: timeout.duration) : nil)
    }
  }

  /// Waits for the transfer `mine` to leave the in-flight map, then reports *its* outcome.
  ///
  /// The exit condition is `!= mine`, never `== nil`: prefetch runs on every reconcile tick and can
  /// re-register the same digest inside a poll window, and a waiter that read that as "still mine"
  /// would wait for a transfer it never joined.
  ///
  /// `limit` is the absolute instant this caller gives up at; `nil` waits as long as it takes.
  func awaitInFlightPull(
    digest: ImageDigest, canonical: OCIReference, mine: Task<ImageRecord, any Error>,
    limit: ContinuousClock.Instant?
  ) async throws -> ImageRecord {
    while inFlightPulls[digest]?.task == mine {
      if let limit, ContinuousClock.now >= limit {
        throw ImageError.pullTimeout(reference: canonical.description)
      }
      try await Task.sleep(for: pullWaitPollInterval)
    }
    // The map entry is cleared only after `performPull` has written the row and finished the
    // operation, so both are already readable here.
    if let record = try await readyRecord(canonical: canonical) {
      return try await touch(record)
    }
    throw await sharedPullFailure(digest: digest, canonical: canonical)
  }

  /// What the shared transfer failed with, as its `pull-image` operation row recorded it. Falls
  /// back to `pullFailed` only when there is nothing to read -- an image row left `invalid` by a
  /// transfer whose operation row could not be written, or no evidence at all.
  private func sharedPullFailure(digest: ImageDigest, canonical: OCIReference) async -> any Error {
    let rows = (try? await operations?.list(state: nil)) ?? []
    let row = rows
      .filter { $0.kind == Self.pullOperationKind && $0.resourceId == digest.rawValue }
      .max { $0.startedAt.date < $1.startedAt.date }
    if let row, row.state == .failed, let code = row.errorCode {
      return SharedPullFailure(code: code, message: row.errorMessage ?? "pull failed")
    }
    return ImageError.pullFailed(reference: canonical.description, cause: nil)
  }

  /// A `ready` row for `ref` without touching the network: a digest reference is its own answer, a
  /// tag one only while its last resolution is still inside `tagResolutionTTL`.
  private func cachedRegistryRecord(_ ref: OCIReference) async throws -> ImageRecord? {
    if let digest = ref.digest {
      return try await readyRecord(canonical: ref.canonical(withDigest: digest))
    }
    guard let cached = tagResolutions[ref.description],
          now().timeIntervalSince(cached.at) < Self.seconds(Self.tagResolutionTTL)
    else { return nil }
    return try await readyRecord(canonical: ref.canonical(withDigest: cached.digest))
  }

  private func readyRecord(canonical: OCIReference) async throws -> ImageRecord? {
    try await images.list(state: .ready).first { $0.canonicalReference == canonical.description }
  }

  @discardableResult
  private func touch(_ record: ImageRecord) async throws -> ImageRecord {
    var updated = record
    updated.lastUsedAt = .now
    try await images.upsert(updated)
    return updated
  }

  // MARK: - Remote inspection

  /// What a registry says about `reference`, without transferring its disk (spec §21, §54).
  ///
  /// Only the manifest and the two small config blobs move, which is the same work `beginPull`
  /// already does before it decides whether to transfer anything -- so this is the cheap half of a
  /// pull, exposed on its own. It exists to answer "how big is it?" before a 16-50 GiB download:
  /// a macOS profile's `resources.disk` must equal the image's virtual size *exactly*, and a Linux
  /// one's must be at least it.
  ///
  /// Purpose is `.storage`, deliberately: inspecting an agentless image must succeed and report
  /// `guestAgent: false`, not be refused the way `.instance` refuses one.
  public func inspectRemote(
    reference: String, format: ImageArtifactFormat? = nil
  ) async throws -> RemoteImageDescription {
    let ref = try Self.requireRegistryReference(reference)
    let remote = try await RunnerVMImageTransfer.inspect(
      ref, registry: try await registries.client(for: ref.registry), require: format)
    // A resolution is a resolution, whoever asked for it: caching it here means the pull that
    // usually follows does not repeat the round trip.
    tagResolutions[ref.description] = (remote.digest, now())
    return RemoteImageDescription(
      reference: ref.canonical(withDigest: remote.digest), manifestDigest: remote.digest,
      format: remote.format, metadata: remote.metadata, transferBytes: remote.transferBytes)
  }

  // MARK: - Pull

  /// Pulls `reference` and waits for it. Concurrent calls for the same resolved digest share one
  /// transfer; `progress` is only wired to the caller that actually starts it.
  @discardableResult
  public func pull(
    reference: String, profile: String? = nil, progress: TransferProgress? = nil,
    format: ImageArtifactFormat? = nil, purpose: ImagePullPurpose = .storage
  ) async throws -> ImageRecord {
    switch try await beginPull(
      reference: reference, profile: profile, progress: progress, format: format, purpose: purpose
    ) {
    case let .present(_, record): return record
    // Nothing bounds this call, so waiting on the shared transfer's own `Task` is safe here —
    // unlike the deadline-bounded `boundedPull`, which polls instead.
    case let .started(_, _, running): return try await running.task.value
    }
  }

  /// Resolves and starts a pull, then returns. The transfer keeps running on this actor, so
  /// `image.pull` can answer an RPC in well under the socket's idle timeout and let the caller
  /// follow the `pull-image` operation instead.
  public func startPull(
    reference: String, profile: String? = nil, format: ImageArtifactFormat? = nil
  ) async throws -> ImagePullStart {
    switch try await beginPull(
      reference: reference, profile: profile, progress: nil, format: format
    ) {
    case let .present(start, _): return start
    // The only place the operation row is waited for: the RPC has to answer with the id the
    // caller follows the transfer by, and no deadline is racing this call.
    case let .started(start, _, running):
      return ImagePullStart(
        reference: start.reference, manifestDigest: start.manifestDigest,
        operationId: await running.operation.value, localDigest: nil)
    }
  }

  func beginPull(
    reference: String, profile: String?, progress: TransferProgress?,
    format: ImageArtifactFormat? = nil, purpose: ImagePullPurpose = .storage
  ) async throws -> PullOutcome {
    let ref = try Self.requireRegistryReference(reference)
    // Deliberately unwrapped: an auth or not-found failure here is the operator's answer, and
    // `REGISTRY_AUTH` says more than `IMAGE_PULL_FAILED` would. Nothing below this line has been
    // written yet, so a format or guest-agent refusal leaves no trace either.
    let remote = try await RunnerVMImageTransfer.inspect(
      ref, registry: try await registries.client(for: ref.registry), require: format,
      purpose: purpose)
    let canonical = ref.canonical(withDigest: remote.digest)
    tagResolutions[ref.description] = (remote.digest, now())
    if let existing = try await readyRecord(canonical: canonical) {
      let refreshed = try await touch(existing)
      return .present(
        ImagePullStart(
          reference: canonical.description, manifestDigest: remote.digest, operationId: nil,
          localDigest: refreshed.digest), refreshed)
    }
    let running = inFlightPulls[remote.digest]
      ?? launchPull(remote: remote, canonical: canonical, profile: profile, progress: progress)
    // `running.operation` is *not* awaited here: it is an unstructured `Task`, and a caller under
    // a deadline (`boundedPull`) would park its task group on it rather than time out.
    return .started(
      ImagePullStart(
        reference: canonical.description, manifestDigest: remote.digest, operationId: nil,
        localDigest: nil), canonical: canonical, running: running)
  }

  /// Synchronous on purpose: everything between the `inFlightPulls` miss above and this
  /// registration must happen without suspending, or spec §137's "one pull, N waiters" turns into
  /// N pulls. Both the operation row and the transfer therefore start as child tasks.
  private func launchPull(
    remote: RunnerVMImageTransfer.RemoteImage, canonical: OCIReference, profile: String?,
    progress: TransferProgress?
  ) -> InFlightPull {
    let kind = Self.pullOperationKind
    let digest = remote.digest.rawValue
    let operation = Task<OperationID?, Never> {
      try? await self.operations?.restart(
        kind: kind, resourceType: "image", resourceId: digest,
        idempotencyKey: "\(kind):\(digest)").id
    }
    let task = Task<ImageRecord, any Error> {
      try await self.performPull(
        remote: remote, canonical: canonical, profile: profile, operation: operation,
        progress: progress)
    }
    let entry = InFlightPull(operation: operation, task: task)
    inFlightPulls[remote.digest] = entry
    return entry
  }

  /// The `pulling` row is keyed by the *registry* manifest digest: the local content digest only
  /// exists once the bytes are on disk, and something has to represent the in-flight image to
  /// `image.list`, `system.status` and the prune rule in the meantime. `transfer` replaces it with
  /// the content-keyed row on success; a failure leaves it `invalid`.
  private func upsertPullingRow(
    remote: RunnerVMImageTransfer.RemoteImage, canonical: OCIReference
  ) async throws {
    let metadata = remote.metadata
    let existing = try await images.get(digest: remote.digest)
    let staging = stagingRoot.appending(
      path: Self.pullStagingName(for: remote.digest), directoryHint: .isDirectory)
    try await images.upsert(
      ImageRecord(
        digest: remote.digest,
        canonicalReference: canonical.description,
        os: metadata.os,
        architecture: metadata.architecture,
        schemaVersion: metadata.schemaVersion,
        metadataJson: String(
          decoding: try JSONEncoder.imageMetadata().encode(metadata), as: UTF8.self),
        localPath: staging.path(percentEncoded: false),
        virtualSizeBytes: metadata.virtualDiskSizeBytes,
        runnerVersion: metadata.runnerVersion,
        guestAgentVersion: metadata.guestAgentVersion,
        state: .pulling,
        createdAt: existing?.createdAt ?? DatabaseDate(metadata.createdAt)))
  }

  private func performPull(
    remote: RunnerVMImageTransfer.RemoteImage, canonical: OCIReference, profile: String?,
    operation: Task<OperationID?, Never>, progress: TransferProgress?
  ) async throws -> ImageRecord {
    defer { inFlightPulls[remote.digest] = nil }
    let operationId = await operation.value
    let startedAt = ContinuousClock.now
    do {
      // Before the concurrency gate: a pull queued behind `concurrentImagePulls` is still an
      // image this host is fetching, and `image.list` / `system.status` must say so.
      try await upsertPullingRow(remote: remote, canonical: canonical)
      let record = try await gated {
        try await self.transfer(remote: remote, canonical: canonical, progress: progress)
      }
      try? await finish(operationId, state: .succeeded, error: nil)
      await metrics.observe(
        RunnerVMMetrics.imagePullSeconds,
        labels: Self.pullLabels(profile: profile, canonical: canonical), since: startedAt)
      logger.info(
        "image pulled",
        metadata: .context(imageDigest: record.digest)
          .merging([
            "reference": .string(canonical.description),
            "format": .string(remote.format.rawValue),
          ]) { $1 })
      return record
    } catch {
      // The staging directory is deliberately kept: the next pull of the same digest resumes into
      // it and re-fetches only the chunks that never verified (spec §119).
      try? await images.setState(digest: remote.digest, from: .pulling, to: .invalid)
      try? await finish(operationId, state: .failed, error: error)
      logger.error(
        "image pull failed",
        metadata: [
          "reference": .string(canonical.description), "error": .string(Self.message(error)),
        ])
      throw ImageError.pullFailed(reference: canonical.description, cause: error as? any RunnerError)
    }
  }

  /// Marks `pulling` rows nothing is pulling any more as `invalid` (spec §119).
  ///
  /// `performPull` sets that state itself on failure, but with a `try?`: a database hiccup on that
  /// one write leaves a row claiming a transfer that ended, which then pins its digest against
  /// `image prune` and makes `image.list` and `system.status` lie for the life of the daemon.
  ///
  /// The in-flight map is the authority on whether a transfer is live: `launchPull` registers an
  /// entry synchronously, before its first `await`, so a miss means no transfer in this process —
  /// and there is only ever one daemon per state directory.
  ///
  /// `firstTick` is what makes that sufficient on its own. Nothing this process did not itself
  /// register can be running yet, so a `pulling` row with no entry is abandoned however its
  /// `pull-image` operation row reads — and after a crash that row is *always* left `running`,
  /// because the daemon that owned it never got to finish it. On later ticks the operation row is
  /// consulted again, since by then a pull may legitimately be resuming one.
  ///
  /// Neither the operation row nor the staging directory is touched: a later pull adopts the
  /// operation through `restart` and resumes into the bytes already staged, which is exactly what
  /// `invalid` (rather than a delete) leaves possible.
  @discardableResult
  public func sweepStalePulls(firstTick: Bool = false) async -> Int {
    guard let rows = try? await images.list(state: .pulling) else { return 0 }
    var running: Set<String> = []
    if !firstTick {
      guard let inProgress = await runningPullDigests() else { return 0 }
      running = inProgress
    }
    var invalidated = 0
    for row in rows
    where inFlightPulls[row.digest] == nil && !running.contains(row.digest.rawValue) {
      guard (try? await images.setState(digest: row.digest, from: .pulling, to: .invalid)) != nil
      else { continue }
      invalidated += 1
      logger.warning(
        "abandoned image pull marked invalid",
        metadata: .context(imageDigest: row.digest).merging([
          "reference": .string(row.canonicalReference ?? "-"),
        ]) { $1 })
    }
    return invalidated
  }

  /// Resource ids of the `pull-image` operations still marked `running`, or `nil` when the rows
  /// exist but could not be read: the sweep then does nothing rather than invalidate a row it
  /// cannot prove is abandoned. A wiring with no operation repository at all has only the
  /// in-flight map to go on, which is the authority inside this process anyway.
  private func runningPullDigests() async -> Set<String>? {
    guard let operations else { return [] }
    guard let rows = try? await operations.list(state: .running) else { return nil }
    return Set(rows.filter { $0.kind == Self.pullOperationKind }.map(\.resourceId))
  }

  private func transfer(
    remote: RunnerVMImageTransfer.RemoteImage, canonical: OCIReference, progress: TransferProgress?
  ) async throws -> ImageRecord {
    try DiskAccounting.hostFreeSpaceCheck(
      paths: paths, reserveBytes: hostReserveDiskBytes, needed: remote.transferBytes)
    let staging = stagingRoot.appending(
      path: Self.pullStagingName(for: remote.digest), directoryHint: .isDirectory)
    let pulled = try await RunnerVMImageTransfer.pull(
      remote, registry: try await registries.client(for: canonical.registry), into: staging,
      progress: progress)
    let imported = try await store.importLocal(
      disk: pulled.diskURL, nvram: pulled.nvramURL, metadata: pulled.metadata,
      name: canonical.description)
    let info = try await store.inspect(digest: imported.digest)
    var record = try makeRecord(
      info: info, directory: imported.manifestDirectory, name: canonical.description)
    record.canonicalReference = canonical.description
    record.lastUsedAt = .now
    try await images.upsert(record)
    if imported.digest != remote.digest { try await images.delete(digest: remote.digest) }
    try? FileManager.default.removeItem(at: staging)
    return record
  }

  // MARK: - Push

  /// Publishes a locally stored image and waits for it. `imageRef` is a local name or `sha256:`
  /// digest; the return value is the immutable `<registry>/<repository>@sha256:…` the registry
  /// served it under.
  ///
  /// The local row's `canonical_reference` is left alone on purpose: pushing a copy somewhere does
  /// not change which reference this host resolved the image from.
  @discardableResult
  public func push(
    imageRef: String, to reference: String, progress: TransferProgress? = nil
  ) async throws -> String {
    try await beginPush(imageRef: imageRef, to: reference, progress: progress).task.value
  }

  /// Validates and starts a push, then returns — same reasoning as `startPull`: a whole disk image
  /// does not fit inside the socket's idle timeout.
  public func startPush(imageRef: String, to reference: String) async throws -> ImagePushStart {
    try await beginPush(imageRef: imageRef, to: reference, progress: nil).start
  }

  private func beginPush(
    imageRef: String, to reference: String, progress: TransferProgress?
  ) async throws -> (start: ImagePushStart, task: Task<String, any Error>) {
    let target = try Self.requireRegistryReference(reference)
    let record = try await record(for: imageRef)
    guard record.state == .ready else {
      throw ImageError.notFound(reference: "\(imageRef) (image is \(record.state.rawValue))")
    }
    let operationId = try await operations?.start(
      kind: Self.pushOperationKind, resourceType: "image", resourceId: record.digest.rawValue,
      idempotencyKey: nil).id
    let task = Task<String, any Error> {
      try await self.performPush(
        record: record, target: target, operationId: operationId, progress: progress)
    }
    return (
      ImagePushStart(
        reference: target.description, digest: record.digest, operationId: operationId), task
    )
  }

  private func performPush(
    record: ImageRecord, target: OCIReference, operationId: OperationID?,
    progress: TransferProgress?
  ) async throws -> String {
    let name = "push-\(UUID().uuidString.lowercased())"
    let staging = stagingRoot.appending(path: name, directoryHint: .isDirectory)
    activePushStaging.insert(name)
    defer {
      activePushStaging.remove(name)
      try? FileManager.default.removeItem(at: staging)
    }
    do {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      let pushed = try await upload(record, to: target, staging: staging, progress: progress)
      // The immutable reference is the one thing the caller could not know when it started the
      // push; the operation row is where `runnerctl image push --wait` reads it back from.
      try? await finish(
        operationId, state: .succeeded, error: nil,
        metadataJson: Self.resultJSON(["pushedReference": pushed]))
      try await touch(record)
      return pushed
    } catch {
      try? await finish(operationId, state: .failed, error: error)
      logger.error(
        "image push failed",
        metadata: .context(imageDigest: record.digest)
          .merging([
            "reference": .string(target.description), "error": .string(Self.message(error)),
          ]) { $1 })
      throw error
    }
  }

  private func upload(
    _ record: ImageRecord, to target: OCIReference, staging: URL, progress: TransferProgress?
  ) async throws -> String {
    let info = try await store.inspect(digest: record.digest)
    let nvram = info.manifest.layer(.nvram) == nil
      ? nil : try await store.blobURL(role: .nvram, digest: record.digest)
    let result = try await RunnerVMImageTransfer.push(
      diskURL: try await store.blobURL(role: .disk, digest: record.digest), nvramURL: nvram,
      metadata: info.metadata, to: target,
      registry: try await registries.client(for: target.registry), staging: staging,
      progress: progress)
    logger.info(
      "image pushed",
      metadata: .context(imageDigest: record.digest)
        .merging(["reference": .string(result.reference.description)]) { $1 })
    return result.reference.description
  }

  // MARK: - Concurrency gate (host.limits.concurrentImagePulls)

  /// Runs `work` holding one of `host.limits.concurrentImagePulls` slots.
  private func gated<T: Sendable>(_ work: () async throws -> T) async rethrows -> T {
    while activePullCount >= concurrentPulls {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        pullWaiters.append(continuation)
      }
    }
    activePullCount += 1
    peakActivePulls = max(peakActivePulls, activePullCount)
    defer {
      activePullCount -= 1
      wakePullWaiters()
    }
    return try await work()
  }

  /// Wakes everyone and lets them re-check: the queue is at most `concurrentImagePulls` deep, so
  /// a thundering herd here is a handful of resumptions, and it cannot lose a wakeup.
  func wakePullWaiters() {
    let waiting = pullWaiters
    pullWaiters = []
    for continuation in waiting { continuation.resume() }
  }

  // MARK: - Helpers

  static func pullStagingName(for digest: ImageDigest) -> String {
    "pull-" + digest.rawValue.replacingOccurrences(of: ":", with: "-")
  }

  static func registryReference(_ text: String) -> OCIReference? {
    guard ImageReference.isValid(text) else { return nil }
    return try? OCIReference(parsing: text)
  }

  static func requireRegistryReference(_ text: String) throws -> OCIReference {
    guard let reference = registryReference(text) else {
      throw ImageError.referenceInvalid(reference: text)
    }
    return reference
  }

  static func pullLabels(profile: String?, canonical: OCIReference) -> [String: String] {
    guard let profile else { return [registryLabel: canonical.registry] }
    return [RunnerVMMetrics.profileLabel: profile]
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }

  private static func message(_ error: any Error) -> String {
    (error as? any RunnerError)?.message ?? String(describing: error)
  }

  private func finish(
    _ id: OperationID?, state: OperationState, error: (any Error)?, metadataJson: String? = nil
  ) async throws {
    guard let id else { return }
    let code = error.map { ($0 as? any RunnerError)?.code ?? "IMAGE_PULL_FAILED" }
    try await operations?.finish(
      id: id, state: state, errorCode: code, errorMessage: error.map(Self.message),
      metadataJson: metadataJson)
  }

  static func resultJSON(_ values: [String: String]) -> String? {
    guard let data = try? JSONSerialization.data(
      withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
