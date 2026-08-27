import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Logging
import Persistence
import RunnerCore
import Scheduler
import Testing

@testable import Orchestration

/// `M2Harness` plus a fully wired `ImageBuilder`, with every host-facing edge replaced by a seam:
/// no `tar`/`hdiutil`, no cloud-image download, no api.github.com. The guest agent and the vmworker
/// are the same in-process fakes the instance tests use, bound in the builder's own namespaces.
struct BuildHarness {
  let base: M2Harness
  let builder: ImageBuilder
  let buildRows: any ImageBuildRepository
  let operations: any OperationRepository
  let processes: RecordingProcessRunner
  let baseImages: FakeBaseImageFetcher
  let releases: FakeRunnerReleaseLookup
  let admissionQueue: AdmissionQueue

  var paths: RunnerPaths { base.paths }
  var tree: TempTree { base.tree }

  /// A tiny build VM: the fixture parent image is a 32 MiB sparse file, and the reservation this
  /// implies has to fit inside whatever free space the developer's Mac happens to have.
  static func configuration(
    maxConcurrent: Int = 1, memoryBytes: UInt64 = ByteSize.gibibytes(1).bytes,
    diskBytes: UInt64 = 64 << 20, stepTimeout: DurationValue = .seconds(30),
    timeout: DurationValue = .seconds(120), maxLogBytes: UInt64 = 1 << 20,
    maxSteps: Int = 256, guestAgentPath: String? = nil
  ) -> RunnerConfiguration {
    var configuration = M2Harness.configuration()
    configuration.build = ImageBuildConfig(
      cpuCount: 2, memoryBytes: memoryBytes, diskBytes: diskBytes, timeout: timeout,
      stepTimeout: stepTimeout, maxConcurrent: maxConcurrent, guestAgentPath: guestAgentPath,
      maxContextBytes: 1 << 20, maxLogBytes: maxLogBytes, maxSteps: maxSteps)
    return configuration
  }

  init(configuration: RunnerConfiguration = BuildHarness.configuration()) async throws {
    base = try await M2Harness(configuration: configuration)
    buildRows = GRDBImageBuildRepository(db: base.database)
    operations = GRDBOperationRepository(db: base.database)
    processes = RecordingProcessRunner()
    baseImages = try FakeBaseImageFetcher(directory: base.tree.root)
    releases = FakeRunnerReleaseLookup()
    admissionQueue = AdmissionQueue()

    var tuning = ImageBuilder.Tuning()
    tuning.agentReachableTimeout = .seconds(20)
    tuning.agentReadyTimeout = .seconds(5)
    tuning.agentReadiness = GuestAgentClient.ReadinessPolicy(
      initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(25))
    tuning.worker.socketPollInterval = .milliseconds(5)
    tuning.worker.socketPollAttempts = 400
    tuning.worker.leaseInterval = .seconds(3_600)
    tuning.workerExitPollInterval = .milliseconds(5)
    tuning.workerExitPollAttempts = 40
    tuning.pumpPollInterval = .milliseconds(20)
    tuning.sealTimeout = .seconds(30)
    tuning.probeTimeout = .seconds(30)
    tuning.gracefulShutdownMs = 1_000
    tuning.processRunner = processes
    tuning.baseImages = baseImages
    tuning.releases = releases

    builder = ImageBuilder(
      paths: base.paths, hostId: base.hostId, builds: buildRows, imageRows: base.imageRows,
      operations: operations, images: base.images, imageStore: base.imageStore,
      buildStore: BuildStore(paths: base.paths, images: base.imageStore, allowFullCopy: true),
      launcher: base.launcher, probe: M2Harness.probe(), instances: base.instanceRows,
      profiles: GRDBProfileRepository(db: base.database),
      hosts: GRDBHostRepository(db: base.database), admissionQueue: admissionQueue,
      metrics: base.metrics, allowFullCopy: true, tuning: tuning,
      logger: Logger(label: "build-test"))
    await builder.updateConfiguration(configuration)
    await base.instances.attachImageBuilds(builder)
  }

  func cleanup() async {
    await builder.stop(cancel: true)
    await base.cleanup()
  }

  // MARK: - Fixtures

  /// Writes a recipe (and, when `context` is given, the files it copies) into a fresh directory.
  @discardableResult
  func writeRecipe(_ text: String, named name: String = "Runnerfile", in directory: String = "recipe")
    throws -> URL
  {
    let root = tree.root.appending(path: directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url
  }

  func writeContextFile(_ relative: String, contents: String, in directory: String = "recipe") throws {
    let url = tree.root.appending(path: directory, directoryHint: .isDirectory)
      .appending(path: relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  /// Binds a fake guest agent where a build's vmworker would publish its bridge.
  func startBuildAgent(
    _ buildId: String, script: FakeGuestAgent.Script = BuildHarness.agentScript()
  ) async throws -> FakeGuestAgent {
    try FileManager.default.createDirectory(
      at: paths.buildSocketDir, withIntermediateDirectories: true)
    let agent = FakeGuestAgent(
      socketPath: paths.buildAgentSocket(ImageBuildID(rawValue: buildId)), script: script)
    try await agent.start()
    return agent
  }

  static let probeOutput = """
    RVM-PROBE-V1
    kernelVersion=6.8.0-31-generic
    architecture=arm64
    runnerVersion=2.330.0
    guestAgentVersion=0.1.0-test
    dockerVersion=26.1.0
    sshEnabled=true
    RVM-PACKAGES-BEGIN
    curl=8.5.0-2
    git=1:2.43.0-1
    RVM-PACKAGES-END

    """

  /// The default guest: every recipe step succeeds, the probe reports a complete image, sealing
  /// prints its marker.
  static func agentScript(
    steps: [FakeGuestAgent.ExecStep] = [.stdout("step ok\n"), .exit(0)],
    health: [HealthResponse] = [HealthResponse(state: .ready)],
    extraRoutes: [FakeGuestAgent.ExecRoute] = []
  ) -> FakeGuestAgent.Script {
    FakeGuestAgent.Script(
      health: health,
      exec: steps,
      execRoutes: extraRoutes + [
        FakeGuestAgent.ExecRoute(match: "rvmctx", steps: [.stdout("context mounted\n"), .exit(0)]),
        FakeGuestAgent.ExecRoute(
          match: "RVM-PROBE-V1", steps: [.stdout(probeOutput), .exit(0)]),
        FakeGuestAgent.ExecRoute(
          match: "RVM-SEAL-OK", steps: [.stdout("RVM-SEAL-OK\n"), .exit(0)]),
      ])
  }

  // MARK: - Assertions

  func row(_ id: String) async throws -> ImageBuildRecord {
    try #require(try await buildRows.get(id: ImageBuildID(rawValue: id)))
  }

  /// Waits for the build to reach a terminal state, then returns the row.
  ///
  /// Builds have no lifecycle event stream to wait on, so this polls; the bound is a hang guard
  /// sized well past the harness's injected `agentReadyTimeout` (5 s), which the old fixed
  /// 400×10 ms budget was *shorter* than -- a never-ready guest could only pass by luck.
  @discardableResult
  func settle(_ id: String) async throws -> ImageBuildRecord {
    try await withHangGuard("build \(id) to finish") {
      while try await !self.row(id).state.isTerminal {
        try await Task.sleep(for: .milliseconds(10))
      }
      return try await self.row(id)
    }
  }

  /// Inserts a build row the way a previous daemon would have left it, with no owning task -- the
  /// shape restart recovery has to deal with.
  @discardableResult
  func seedBuildRow(
    state: ImageBuildState, name: String? = nil, imageDigest: ImageDigest? = nil,
    withDirectory: Bool = true
  ) async throws -> ImageBuildID {
    let id = ImageBuildID.generate()
    if withDirectory {
      try FileManager.default.createDirectory(
        at: paths.buildVMDir(id), withIntermediateDirectories: true)
    }
    try await buildRows.insert(
      ImageBuildRecord(
        id: id, hostId: base.hostId, name: name, state: state, recipePath: "/tmp/Runnerfile",
        recipeSHA256: "sha256:" + String(repeating: "0", count: 64), contextPath: "/tmp",
        fromKind: .image, fromReference: M2Harness.linuxImageName, cpuCount: 2,
        memoryBytes: 1 << 30, diskBytes: 64 << 20, diskReservationBytes: 64 << 20,
        timeoutMs: 60_000, buildPath: paths.buildDir(id).path(percentEncoded: false),
        logPath: paths.buildLogFile(id).path(percentEncoded: false),
        imageDigest: imageDigest, createdAt: .now, updatedAt: .now))
    return id
  }

  func buildLog(_ id: String) -> String {
    (try? String(contentsOf: paths.buildLogFile(ImageBuildID(rawValue: id)), encoding: .utf8)) ?? ""
  }
}

/// Runs `body` with a fresh `BuildHarness`, guaranteeing cleanup -- the builder's tasks are
/// cancelled and awaited before the temp tree goes away, so nothing is still writing into it.
func withBuildHarness(
  configuration: RunnerConfiguration = BuildHarness.configuration(),
  _ body: (BuildHarness) async throws -> Void
) async throws {
  let harness = try await BuildHarness(configuration: configuration)
  do {
    try await body(harness)
  } catch {
    await harness.cleanup()
    throw error
  }
  await harness.cleanup()
}

// MARK: - Seams

/// Stands in for `tar` and `hdiutil`: records the argv, and produces the file the real tool would
/// have, so the packer's own hashing and renaming still run for real.
final class RecordingProcessRunner: ProcessRunner, @unchecked Sendable {
  struct Invocation: Sendable {
    var executable: String
    var arguments: [String]
    /// For `hdiutil makehybrid`, the files that were staged in the payload directory, relative to
    /// it -- the only way to inspect a seed or context before it becomes an opaque ISO.
    var payload: [String: String]
  }

  private let lock = NSLock()
  private var recorded: [Invocation] = []

  var invocations: [Invocation] { lock.withLock { recorded } }

  func calls(of tool: String) -> [Invocation] {
    invocations.filter { $0.executable.hasSuffix(tool) }
  }

  func run(
    _ executable: String, _ arguments: [String], timeout: Duration
  ) async throws -> ProcessResult {
    var payload: [String: String] = [:]
    if executable.hasSuffix("hdiutil"), let source = arguments.last {
      payload = Self.snapshot(URL(fileURLWithPath: source))
    }
    lock.withLock {
      recorded.append(Invocation(executable: executable, arguments: arguments, payload: payload))
    }
    if executable.hasSuffix("tar"), let index = arguments.firstIndex(of: "-cf") {
      try Data("fake tar\n".utf8).write(to: URL(fileURLWithPath: arguments[index + 1]))
    }
    if executable.hasSuffix("hdiutil"), let index = arguments.firstIndex(of: "-o") {
      try Data("fake iso\n".utf8).write(to: URL(fileURLWithPath: arguments[index + 1]))
    }
    return ProcessResult(exitCode: 0)
  }

  private static func snapshot(_ root: URL) -> [String: String] {
    guard let walker = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
    else { return [:] }
    var result: [String: String] = [:]
    for case let relative as String in walker {
      let url = root.appending(path: relative)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(
        atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      result[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    return result
  }
}

/// Hands back a prepared raw disk instead of downloading and converting a cloud image.
final class FakeBaseImageFetcher: BaseImageFetcher, @unchecked Sendable {
  let raw: URL
  private let lock = NSLock()
  private var recorded: [(location: String, sha256: String, noCache: Bool)] = []
  private var failure: (any Error)?

  var requests: [(location: String, sha256: String, noCache: Bool)] {
    lock.withLock { recorded }
  }

  init(directory: URL, bytes: UInt64 = 64 << 20) throws {
    raw = directory.appending(path: "base-cloud.raw")
    FileManager.default.createFile(atPath: raw.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: raw)
    try handle.truncate(atOffset: bytes)
    try handle.close()
  }

  func failNext(_ error: any Error) {
    lock.withLock { failure = error }
  }

  func fetch(location: String, sha256: String, noCache: Bool) async throws -> FetchedBaseImage {
    let pending: (any Error)? = lock.withLock {
      recorded.append((location, sha256, noCache))
      let queued = failure
      failure = nil
      return queued
    }
    if let pending { throw pending }
    return FetchedBaseImage(
      raw: raw, sourceSHA256: "sha256:\(sha256)", rawSHA256: "sha256:" + String(repeating: "a", count: 64),
      virtualBytes: 64 << 20, source: location, cacheHit: false)
  }
}

/// GitHub's release metadata, without GitHub.
final class FakeRunnerReleaseLookup: RunnerReleaseLookup, @unchecked Sendable {
  private let lock = NSLock()
  private var _version: String? = "2.330.0"
  private var _digest: String? = "sha256:" + String(repeating: "b", count: 64)

  func set(version: String?, digest: String?) {
    lock.withLock {
      _version = version
      _digest = digest
    }
  }

  func latestVersion() async throws -> String? { lock.withLock { _version } }

  func assetDigest(version: String, asset: String) async throws -> String? {
    lock.withLock { _digest }
  }
}
