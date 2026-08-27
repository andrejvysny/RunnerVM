import DaemonAPI
import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Persistence
import RunnerCore
import Scheduler
import Testing

@testable import Orchestration

/// Admission, capacity, restart recovery, argument resolution and the intake refusals -- everything
/// around the stage ladder rather than inside it.
@Suite(.serialized)
struct ImageBuilderAdmissionTests {
  private static let stalling = """
    FROM test-linux
    RUN /bin/sleep 600

    """

  private func stall() -> FakeGuestAgent.Script {
    BuildHarness.agentScript(steps: [.stall(.seconds(30)), .exit(0)])
  }

  // MARK: - Concurrency and capacity

  @Test func aSecondBuildIsRefusedWhileOneIsRunning() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      let request = ImageBuildRequest(
        recipePath: recipe.path(percentEncoded: false), name: "concurrent")
      let started = try await harness.builder.start(request)
      let agent = try await harness.startBuildAgent(started.buildId, script: stall())

      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(request)
      }
      #expect(error?.code == "BUILD_AT_MAX_CONCURRENT")
      #expect(try await harness.buildRows.list(states: nil).count == 1)
      await agent.stop()
    }
  }

  @Test func twoConcurrentStartsAdmitExactlyOne() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      let builder = harness.builder
      let request = ImageBuildRequest(
        recipePath: recipe.path(percentEncoded: false), name: "racing")

      async let first = try? await builder.start(request)
      async let second = try? await builder.start(request)
      let outcomes = await [first, second].compactMap { $0 }
      #expect(outcomes.count == 1, "the admission queue must serialize the concurrency gate")
      #expect(try await harness.buildRows.list(states: nil).count == 1)
      if let admitted = outcomes.first {
        let agent = try await harness.startBuildAgent(admitted.buildId, script: stall())
        await agent.stop()
      }
    }
  }

  @Test func aRunningBuildReducesTheCapacityAdvertisedForARealProfile() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      let profiles = GRDBProfileRepository(db: harness.base.database)
      let row = try #require(try await profiles.get(name: "linux"))
      let profile = try row.decodedConfig()
      let budget = InstanceAdmission.budget(
        configuration: BuildHarness.configuration(), probe: M2Harness.probe(),
        paths: harness.paths)
      let idle = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: profile, reservations: [], budget: budget, hostMode: .normal)

      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "capacity"))
      let agent = try await harness.startBuildAgent(started.buildId, script: stall())
      let reservations = try await InstanceAdmission.reservations(
        instances: harness.base.instanceRows, profiles: profiles, builds: harness.builder)
      #expect(reservations.count { $0.isImageBuild } == 1)
      let busy = CapacityCalculator.profileCapacity(
        profileId: row.id, profile: profile, reservations: reservations, budget: budget,
        hostMode: .normal)
      #expect(busy.cap < idle.cap)
      // The sentinel profile must never be counted as an instance of a real one.
      #expect(busy.currentInstances == 0)
      await agent.stop()
    }
  }

  @Test func pruneKeepsTheParentImageWhileABuildIsRunning() async throws {
    try await withBuildHarness { harness in
      let parent = try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "pinned"))
      let agent = try await harness.startBuildAgent(started.buildId, script: stall())
      try await waitUntil("the base to be pinned") {
        try await harness.base.imageRows.pinCount(digest: parent.record.digest) > 0
      }

      var policy = ImageCacheConfig()
      policy.keepRecentlyUsed = .zero
      let report = try await harness.base.images.prune(
        policy: policy, dryRun: false, now: Date().addingTimeInterval(3_600))
      #expect(report.deleted.isEmpty)
      #expect(report.keptPinned.contains(parent.record.digest))
      #expect(try await harness.base.imageRows.get(digest: parent.record.digest) != nil)
      await agent.stop()
    }
  }

  // MARK: - Restart recovery

  @Test func aBuildLeftBehindByARestartIsFailedAndCleanedUp() async throws {
    try await withBuildHarness { harness in
      let parent = try await harness.base.importLinuxImage()
      let id = try await harness.seedBuildRow(state: .provisioning, name: "interrupted")
      try await harness.base.imageRows.pin(
        ownerType: .build, ownerId: id.rawValue, digest: parent.record.digest)

      #expect(await harness.builder.recover() == 1)

      let row = try await harness.row(id.rawValue)
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_INTERRUPTED")
      #expect(!FileManager.default.fileExists(
        atPath: harness.paths.buildDir(id).path(percentEncoded: false)))
      #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    }
  }

  @Test func aSealedBuildThatCrashedBeforeRegistrationIsReplayed() async throws {
    try await withBuildHarness { harness in
      // Content in the store but no `images` row: exactly the window `setImageDigest`-before-delete
      // was ordered to make recoverable (B4).
      let disk = try harness.base.sparseFile(named: "sealed.img", bytes: 8 << 20)
      let sealed = try await harness.base.imageStore.importLocal(
        disk: disk, nvram: nil,
        metadata: ImageMetadata(
          os: .linux, virtualDiskSizeBytes: 8 << 20, createdAt: Date(),
          boot: ImageMetadata.Boot(type: .efi),
          capabilities: ImageMetadata.Capabilities(guestAgent: true)),
        name: "replayed")
      #expect(try await harness.base.imageRows.get(digest: sealed.digest) == nil)
      let id = try await harness.seedBuildRow(
        state: .sealing, name: "replayed", imageDigest: sealed.digest)

      #expect(await harness.builder.recover() == 1)

      let row = try await harness.row(id.rawValue)
      #expect(row.state == .succeeded)
      #expect(row.failureCode == nil)
      #expect(try await harness.base.imageRows.get(digest: sealed.digest) != nil)
      #expect(try await harness.base.imageRows.alias(name: "replayed") == sealed.digest)
    }
  }

  @Test func aBuildDirectoryWithNoRowIsSweptAway() async throws {
    try await withBuildHarness { harness in
      let orphan = harness.paths.buildDir(ImageBuildID.generate())
      try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
      _ = await harness.builder.recover()
      #expect(!FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))
    }
  }

  // MARK: - Intake refusals

  @Test func aBaseWithoutAGuestAgentIsRefused() async throws {
    try await withBuildHarness { harness in
      let disk = try harness.base.sparseFile(named: "agentless.img", bytes: 8 << 20)
      _ = try await harness.base.images.importLocal(
        disk: disk, nvram: nil, os: .linux, name: "agentless", guestAgent: false)
      let recipe = try harness.writeRecipe("""
        FROM agentless
        RUN /bin/echo hi

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "no-agent"))
      let row = try await harness.settle(started.buildId)
      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_BASE_NO_GUEST_AGENT")
      #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    }
  }

  @Test func anUnreadableRecipeNamesThePathAndTheDaemonUID() async throws {
    try await withBuildHarness { harness in
      let missing = harness.tree.root.appending(path: "nowhere/Runnerfile")
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: missing.path(percentEncoded: false), name: "missing"))
      }
      #expect(error?.code == "BUILD_RECIPE_UNREADABLE")
      #expect(error?.message.contains("nowhere/Runnerfile") == true)
      #expect(error?.message.contains("uid \(geteuid())") == true)
      let rows = try await harness.buildRows.list(states: nil)
      #expect(rows.isEmpty)
    }
  }

  @Test func aRecipeWithMoreStepsThanTheLimitIsRefused() async throws {
    try await withBuildHarness(configuration: BuildHarness.configuration(maxSteps: 2)) { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(
        "FROM test-linux\n" + String(repeating: "RUN /bin/echo hi\n", count: 3))
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "long"))
      }
      #expect(error?.code == "BUILD_TOO_MANY_STEPS")
      let rows = try await harness.buildRows.list(states: nil)
      #expect(rows.isEmpty)
    }
  }

  // MARK: - Build context

  @Test func aSymlinkEscapingTheContextIsRefused() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        COPY app /opt/app

        """)
      let context = recipe.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: context.appending(path: "app"), withIntermediateDirectories: true)
      let secret = harness.tree.root.appending(path: "outside.txt")
      try Data("secret\n".utf8).write(to: secret)
      try FileManager.default.createSymbolicLink(
        at: context.appending(path: "app/escape"), withDestinationURL: secret)

      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "escape"))
      }
      #expect(error?.code == "BUILD_CONTEXT_UNSAFE_ENTRY")
      #expect(try await harness.buildRows.list(states: nil).isEmpty)
    }
  }

  @Test func anOversizedContextIsRefusedNamingItsLargestEntries() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        COPY app /opt/app

        """)
      try harness.writeContextFile(
        "app/big.bin", contents: String(repeating: "z", count: 2 << 20))
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "too-big"))
      }
      #expect(error?.code == "BUILD_CONTEXT_TOO_LARGE")
      #expect(error?.message.contains("app/big.bin") == true)
    }
  }

  @Test func theContextIsHashedWhenStartReturnsNotWhenTheBuildRuns() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        COPY app /opt/app
        RUN /bin/sleep 600

        """)
      try harness.writeContextFile("app/main.sh", contents: "original\n")
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "frozen"))
      let atStart = try await harness.row(started.buildId).contextSHA256
      #expect(atStart != nil)

      // The operator's tree is theirs again the moment `start` answered (N2).
      try harness.writeContextFile("app/main.sh", contents: "changed after start\n")
      try harness.writeContextFile("app/extra.sh", contents: "added after start\n")
      let agent = try await harness.startBuildAgent(started.buildId, script: stall())
      try await waitUntil("the build to reach provisioning") {
        try await harness.row(started.buildId).state == .provisioning
      }
      #expect(try await harness.row(started.buildId).contextSHA256 == atStart)
      #expect(harness.processes.calls(of: "tar").count == 1)
      await agent.stop()
    }
  }

  // MARK: - Build arguments

  private static let runnerRecipe = """
    FROM test-linux
    ARG RUNNER_VERSION=latest
    ARG RUNNER_SHA256
    LABEL dev.runnervm.image.name=runner-args
    RUN /bin/echo ${RUNNER_VERSION} ${RUNNER_SHA256}

    """

  @Test func latestResolvesToAConcreteVersionAndGitHubsAssetDigest() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.runnerRecipe)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false)))
      let agent = try await harness.startBuildAgent(started.buildId)
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .succeeded, "\(row.failureCode ?? "-"): \(row.failureMessage ?? "-")")
      #expect(row.argsJson.contains("\"RUNNER_VERSION\":\"2.330.0\""))
      let digest = try #require(row.imageDigest)
      let runner = try await harness.base.images.get(reference: digest.rawValue)
        .metadata?.provenance?.actionsRunner
      #expect(runner?.version == "2.330.0")
      #expect(runner?.digestSource == "github-release-asset")
      #expect(runner?.sha256 == String(repeating: "b", count: 64))
    }
  }

  @Test func anOperatorPinThatDisagreesWithGitHubIsRefused() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.runnerRecipe)
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(
            recipePath: recipe.path(percentEncoded: false),
            args: ["RUNNER_SHA256": String(repeating: "d", count: 64)]))
      }
      #expect(error?.code == "BUILD_RUNNER_DIGEST_MISMATCH")
    }
  }

  @Test func aReleaseWithNoPublishedDigestFailsClosed() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      harness.releases.set(version: "2.330.0", digest: nil)
      let recipe = try harness.writeRecipe(Self.runnerRecipe)
      let error = await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false)))
      }
      #expect(error?.code == "BUILD_RUNNER_DIGEST_UNAVAILABLE")
    }
  }

  // MARK: - Push, drain, shutdown

  @Test func pushStartsALinkedOperationWithoutGatingSuccess() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo hi

        """)
      let target = try harness.base.registry.reference("acme/built", tag: "v1").description
      let started = try await harness.builder.start(
        ImageBuildRequest(
          recipePath: recipe.path(percentEncoded: false), name: "pushed", push: target))
      let agent = try await harness.startBuildAgent(started.buildId)
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .succeeded, "\(row.failureCode ?? "-"): \(row.failureMessage ?? "-")")
      #expect(row.pushReference == target)
      try await waitUntil("the push operation to be linked") {
        try await harness.row(started.buildId).pushOperationId != nil
      }
      let operationId = try #require(try await harness.row(started.buildId).pushOperationId)
      let push = try #require(
        try await harness.operations.list(state: nil).first { $0.id == operationId })
      #expect(push.kind == "push-image")
    }
  }

  @Test func aDrainingHostAdmitsNoBuilds() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      try await GRDBHostRepository(db: harness.base.database).setMode(
        id: harness.base.hostId, from: .normal, to: .draining)
      await #expect(throws: DaemonServiceError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "drained"))
      }
      #expect(try await harness.buildRows.list(states: nil).isEmpty)
    }
  }

  @Test func forcedShutdownCancelsARunningBuildAndReturns() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.stalling)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "forced"))
      let agent = try await harness.startBuildAgent(started.buildId, script: stall())
      try await waitUntil("the build to reach provisioning") {
        try await harness.row(started.buildId).state == .provisioning
      }
      await harness.builder.stop(cancel: true)
      #expect(try await harness.row(started.buildId).state == .cancelled)
      await agent.stop()
    }
  }
}
