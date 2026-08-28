import CryptoKit
import Foundation
import ImageStore
import OCIRegistry
import Persistence
import RunnerCore
import Scheduler

/// The synchronous half of a managed macOS provisioning build, and the one entry point the update
/// service drives it through.
///
/// Mirrors `ImageBuilderStart`'s discipline: everything that can be settled before a build row
/// exists is settled here, so a missing script, an upstream that is not a macOS Tart image, or a
/// host with no room is an error the caller sees rather than a build row that fails a moment later.
///
/// It differs in one deliberate way. A Runnerfile build is admitted and *then* resolves its base;
/// this one pulls first, because the reservation is sized from the upstream image's own disk and a
/// macOS disk is the dominant term by two orders of magnitude. The pull is a `pull-image`
/// operation of its own and is visible as one whether or not a build follows it.
extension ImageBuilder {
  /// Starts a provisioning build and answers as soon as the row exists. `provisionManaged` is what
  /// waits for it.
  public func startMacOSProvision(
    managed: ManagedImageSourceConfig, sourceDigest: String? = nil, debugSSH: Bool = false
  ) async throws -> ImageBuildID {
    try await refuseWhenClosed()
    let config = buildConfig
    let script = try MacOSProvisionAssets.resolveScript(config: config, paths: paths)
    let agentBinary = try MacOSProvisionAssets.resolveDarwinAgent(config: config, paths: paths)

    // Before the reservation, because it is what sizes it: a macOS image's disk is 60-100 GiB and
    // no assumed figure would be honest about it (contrast `assumedBaseImageBytes`, which is a
    // guess only because a cloud image's size is not knowable without downloading it).
    let record = try await images.pull(
      reference: managed.source, purpose: .provisioningBase)
    let info = try await imageStore.inspect(digest: record.digest)
    guard info.metadata.os == .macos else {
      throw ImageBuildError.baseFormatUnsupported(
        reason: "\(managed.source) is a \(info.metadata.os.rawValue) image; "
          + "images.managed[kind: macosTart] has to name a macOS one")
    }
    // Refused here rather than at boot: an image with no hardware model or no boot minimums can
    // never be booted at all, and finding that out after a 60 GiB pull and a clone helps nobody.
    _ = try InstanceManager.macOSPlatform(image: info)

    let id = ImageBuildID.generate()
    let resources = managed.resources ?? ManagedImageSourceConfig.Resources()
    let diskBytes = Self.macOSDiskBytes(info)
    let input = BuildInput(
      id: id, kind: .macosProvision, name: managed.name, recipe: nil, plan: nil,
      contextPath: script.deletingLastPathComponent().path(percentEncoded: false),
      packed: nil, args: [:], runnerSudo: true, cpuCount: resources.cpuCount,
      memoryBytes: resources.memoryBytes, diskBytes: diskBytes,
      reservationBytes: macOSReservation(diskBytes: diskBytes, config: config),
      timeout: config.timeout.duration, stepTimeout: config.stepTimeout.duration, push: nil,
      noCache: false,
      macos: MacOSProvisionInput(
        managedName: managed.name, sourceReference: managed.source, sourceDigest: sourceDigest,
        script: script, scriptSHA256: Self.sha256(of: script) ?? "", agentBinary: agentBinary,
        debugSSH: debugSSH))

    let operation = OperationRecord(
      id: OperationID.generate(), kind: Self.operationKind, resourceType: "image-build",
      resourceId: id.rawValue, state: .running, startedAt: .now)
    var row = macOSRecord(input: input, macos: input.macos!, baseDigest: record.digest)
    row.operationId = operation.id
    try await admit(record: row, operation: operation, input: input, guestOS: .macos)

    let run = BuildRun(input: input)
    run.operationId = operation.id
    runs[id] = run
    tasks[id] = Task { [weak self] in await self?.execute(id) }
    logger.info(
      "macOS provisioning build queued",
      metadata: [
        "build_id": .string(id.rawValue), "managed": .string(managed.name),
        "source": .string(managed.source), "source_digest": .string(sourceDigest ?? "-"),
      ])
    return id
  }

  /// Starts a provisioning build for `track` and waits for it, answering with the digest it sealed
  /// and *qualified*. Throws whatever failed it.
  ///
  /// This is what `MacOSProvisionLauncher` fronts. Awaiting the owned `Task` rather than polling
  /// the row is what makes "the build finished" and "the terminal row is written" the same
  /// instant: `finish` writes that row before the task completes.
  public func provisionManaged(
    _ track: ManagedImageRecord, sourceDigest: String? = nil
  ) async throws -> ImageDigest {
    let source = configuration?.images.managed.first { $0.name == track.name }
      ?? ManagedImageSourceConfig(
        name: track.name, kind: track.kind, source: track.sourceReference,
        autoUpdate: track.autoUpdate)
    let id = try await startMacOSProvision(managed: source, sourceDigest: sourceDigest)
    await tasks[id]?.value
    let row = try await require(id)
    guard row.state == .succeeded, let digest = row.imageDigest else {
      // The build's own failure *code* travels with the reason: this string becomes the managed
      // track's `last_error`, and `BUILD_MACOS_QUALIFICATION_FAILED` is what tells an operator
      // which half of the run went wrong without opening `build show`.
      let detail = [row.failureCode, row.failureMessage].compactMap { $0 }.joined(separator: ": ")
      throw ImageBuildError.macosProvisionFailed(
        reason: "build \(id.rawValue) ended \(row.state.rawValue): "
          + (detail.isEmpty ? "no reason recorded" : detail))
    }
    return digest
  }

  // MARK: - Row

  private func macOSRecord(
    input: BuildInput, macos: MacOSProvisionInput, baseDigest: ImageDigest
  ) -> ImageBuildRecord {
    ImageBuildRecord(
      id: input.id, hostId: hostId, name: macos.managedName, state: .queued,
      // The script *is* this build's recipe: it is the file whose contents decide what the guest
      // becomes, and pinning its digest on the row is the same provenance a Runnerfile gets.
      recipePath: macos.script.path(percentEncoded: false), recipeSHA256: macos.scriptSHA256,
      contextPath: input.contextPath, fromKind: .registry, fromReference: macos.sourceReference,
      baseDigest: baseDigest, baseSHA256: baseDigest.rawValue, cpuCount: input.cpuCount,
      memoryBytes: input.memoryBytes, diskBytes: input.diskBytes,
      diskReservationBytes: input.reservationBytes, timeoutMs: input.timeout.milliseconds,
      buildPath: paths.buildDir(input.id).path(percentEncoded: false),
      logPath: paths.buildLogFile(input.id).path(percentEncoded: false), createdAt: .now,
      updatedAt: .now, kind: .macosProvision, managedName: macos.managedName,
      sourceDigest: macos.sourceDigest)
  }

  /// Worst case for the whole run.
  ///
  /// One clone of the base disk, plus the log cap, plus -- on a host with no clone-capable volume
  /// -- a second full disk for the sealing copy. The cold-boot qualification clone is deliberately
  /// *not* a third term: the provisioning VM's directory is released the moment the image is
  /// sealed, before that clone is made, so the two never coexist.
  private func macOSReservation(diskBytes: UInt64, config: ImageBuildConfig) -> UInt64 {
    var total = diskBytes + config.maxLogBytes
    if allowFullCopy { total += diskBytes }
    return total
  }

  static func sha256(of url: URL) -> String? {
    guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
      return nil
    }
    return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// `ImageUpdateService`'s D6 seam, implemented.
///
/// A thin adapter rather than a conformance on `ImageBuilder` itself: `MacOSProvisionLauncher`
/// lives with the update service and exists to keep that service from knowing what an image build
/// is, and the daemon's composition root is the only place the two are introduced.
public struct MacOSProvisionLaunching: MacOSProvisionLauncher {
  private let builder: ImageBuilder

  public init(builder: ImageBuilder) {
    self.builder = builder
  }

  public func provision(
    _ track: ManagedImageRecord, sourceDigest: String
  ) async throws -> ImageDigest {
    try await builder.provisionManaged(track, sourceDigest: sourceDigest)
  }
}
