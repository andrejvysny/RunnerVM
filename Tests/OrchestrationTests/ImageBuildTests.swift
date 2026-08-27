import DaemonAPI
import Foundation
import GuestControl
import ImageBuild
import ImageStore
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

/// The in-daemon image builder's stage ladder, end to end against fakes: a real `RPCServer` guest
/// agent bound where a build's vmworker would publish its bridge, a real image store, real
/// persistence, and the `tar`/`hdiutil`/network edges replaced by seams.
@Suite(.serialized)
struct ImageBuilderLifecycleTests {
  private static let derivedRecipe = """
    FROM test-linux
    LABEL dev.runnervm.image.name=built-linux
    LABEL org.example.tier=ci
    RUN /bin/echo hello-from-step
    COPY app /opt/app

    """

  @Test func aDerivedBuildSealsRegistersAndAliasesANewImage() async throws {
    try await withBuildHarness { harness in
      let parent = try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe(Self.derivedRecipe)
      try harness.writeContextFile("app/main.sh", contents: "#!/bin/sh\necho hi\n")

      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.deletingLastPathComponent().path(percentEncoded: false)))
      let agent = try await harness.startBuildAgent(started.buildId)
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .succeeded, "\(row.failureCode ?? "-"): \(row.failureMessage ?? "-")")
      #expect(row.name == "built-linux")
      #expect(row.totalSteps == 2)
      #expect(row.operationId?.rawValue == started.operationId)
      let digest = try #require(row.imageDigest)
      let sealed = try await harness.base.images.get(reference: digest.rawValue)
      #expect(sealed.metadata?.capabilities.labels?["org.example.tier"] == "ci")
      #expect(sealed.metadata?.capabilities.guestAgent == true)
      #expect(sealed.metadata?.provenance?.recipe?.sha256 == row.recipeSHA256)
      #expect(sealed.metadata?.provenance?.parentImageDigest == parent.record.digest.rawValue)
      #expect(sealed.metadata?.runnerVersion == "2.330.0")
      // The alias is what makes `--name` mean this digest from now on (B5).
      #expect(try await harness.base.imageRows.alias(name: "built-linux") == digest)

      let log = harness.buildLog(started.buildId)
      #expect(log.contains("[stdout] step ok"))
      #expect(log.contains("RVM-SEAL-OK"))
      #expect(log.contains("[1/2]") && log.contains("[2/2]"))
      #expect(!FileManager.default.fileExists(
        atPath: harness.paths.buildDir(row.id).path(percentEncoded: false)))
      #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
      #expect(try await harness.builder.activeBuildReservations().isEmpty)
      let operation = try #require(
        try await harness.operations.list(state: nil).first { $0.kind == "build-image" })
      #expect(operation.state == .succeeded)
    }
  }

  @Test func aBootstrapBuildWritesACloudInitSeedAndConvertsTheCloudBase() async throws {
    try await withBuildHarness { harness in
      let hex = String(repeating: "c", count: 64)
      let recipe = try harness.writeRecipe("""
        FROM cloud-image:https://example.invalid/noble.img --sha256=\(hex)
        LABEL dev.runnervm.image.name=bootstrapped
        RUN /bin/echo installing

        """)
      let agentBinary = harness.tree.root.appending(path: "runnervm-guest-agent")
      try Data("#!/bin/true\n".utf8).write(to: agentBinary)

      var configuration = BuildHarness.configuration()
      configuration.build.guestAgentPath = agentBinary.path(percentEncoded: false)
      await harness.builder.updateConfiguration(configuration)

      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false)))
      let agent = try await harness.startBuildAgent(started.buildId)
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .succeeded, "\(row.failureCode ?? "-"): \(row.failureMessage ?? "-")")
      #expect(harness.baseImages.requests.first?.sha256 == hex)
      let seed = try #require(
        harness.processes.calls(of: "hdiutil").first { $0.arguments.contains("cidata") })
      let userData = try #require(seed.payload["user-data"])
      #expect(userData.hasPrefix("#cloud-config"))
      #expect(userData.contains("serial-getty@hvc0.service"))
      #expect(userData.contains("console=hvc0"))
      #expect(userData.contains("uid: 1001"))
      #expect(userData.contains("NOPASSWD:ALL"))
      #expect(userData.contains("systemctl enable --now runnervm-guest-agent.service"))
      // A bootstrap seed installs nothing and powers nothing off: the builder decides when the VM
      // stops, and cloud-init `packages:` would race the recipe's own steps.
      #expect(!userData.contains("power_state"))
      #expect(!userData.contains("\npackages:"))
      #expect(seed.payload["meta-data"]?.contains(started.buildId) == true)
      #expect(seed.payload["runnervm/runnervm-guest-agent.service"]?.contains("vsock") == true)
      #expect(row.baseSHA256 == "sha256:\(hex)")
    }
  }

  @Test func aGuestThatNeverBecomesReadyIsNotSealed() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo hi

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "never-ready"))
      // Reachable (hello answers) but never `ready`: exactly the bootstrap case B1 describes,
      // except the recipe never installed the runner.
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(
          health: [HealthResponse(state: .degraded, reasons: ["runner is not installed"])]))
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_IMAGE_NOT_READY")
      #expect(row.failureMessage?.contains("runner is not installed") == true)
      #expect(row.imageDigest == nil)
      #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    }
  }

  @Test func aFailingStepReportsItsIndexLineAndOutput() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo first
        RUN /bin/false

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "step-fail"))
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(extraRoutes: [
          FakeGuestAgent.ExecRoute(
            match: "/bin/false", steps: [.stderr("boom\n"), .exit(3)]),
        ]))
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_STEP_FAILED")
      #expect(row.failureMessage?.contains("step 2") == true)
      #expect(row.failureMessage?.contains("boom") == true)
      #expect(row.imageDigest == nil)
      #expect(try await harness.base.images.list().count == 1)
      #expect(!FileManager.default.fileExists(
        atPath: harness.paths.buildDir(row.id).path(percentEncoded: false)))
      #expect(try await harness.base.imageRows.pins(ownerType: .build).isEmpty)
    }
  }

  @Test func aStepThatFloodsTheLogFailsTheBuild() async throws {
    try await withBuildHarness(configuration: BuildHarness.configuration(maxLogBytes: 512)) { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo flood

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "flood"))
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(
          steps: [.stdout(String(repeating: "x", count: 40) + "\n")] + Array(
            repeating: FakeGuestAgent.ExecStep.stdout(String(repeating: "y", count: 60) + "\n"),
            count: 40) + [.exit(0)]))
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_STEP_OUTPUT_TOO_LARGE")
    }
  }

  @Test func aSilentGuestTripsTheHostSideIdleTimeout() async throws {
    let configuration = BuildHarness.configuration(stepTimeout: .seconds(1))
    try await withBuildHarness(configuration: configuration) { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/sleep 600

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "stalled"))
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(steps: [.stall(.seconds(30)), .exit(0)]))
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_STEP_TIMEOUT")
    }
  }

  @Test func theWholeBuildDeadlineIsEnforced() async throws {
    let configuration = BuildHarness.configuration(
      stepTimeout: .seconds(30), timeout: .milliseconds(1))
    try await withBuildHarness(configuration: configuration) { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo slow

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "too-slow"))
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(steps: [.stall(.seconds(20)), .exit(0)]))
      let row = try await harness.settle(started.buildId)
      await agent.stop()

      #expect(row.state == .failed)
      #expect(row.failureCode == "BUILD_TIMEOUT")
    }
  }

  @Test func cancellingMidProvisioningLeavesNoImage() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/sleep 600
        RUN /bin/echo never

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "cancelled"))
      let agent = try await harness.startBuildAgent(
        started.buildId,
        script: BuildHarness.agentScript(steps: [.stall(.seconds(30)), .exit(0)]))
      try await waitUntil("the build to reach provisioning") {
        try await harness.row(started.buildId).state == .provisioning
      }
      let response = try await harness.builder.cancel(id: started.buildId)
      #expect(response.buildId == started.buildId)
      let row = try await harness.settle(started.buildId)
      #expect(row.state == .cancelled)
      #expect(row.imageDigest == nil)
      // The second RUN never ran: cancellation stops the ladder, it does not skip a step.
      #expect(await agent.execHistory().count == 1)
      #expect(await agent.cancelledExecCount() == 1)
      await agent.stop()
      #expect(try await harness.base.images.list().count == 1)
    }
  }

  @Test func theImageNameComesFromTheLabelWhenNoNameIsGiven() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let labelled = try harness.writeRecipe("""
        FROM test-linux
        LABEL dev.runnervm.image.name=from-label
        RUN /bin/echo hi

        """, in: "labelled")
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: labelled.path(percentEncoded: false)))
      #expect(started.name == "from-label")

      let anonymous = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo hi

        """, in: "anonymous")
      await #expect(throws: ImageBuildError.self) {
        _ = try await harness.builder.start(
          ImageBuildRequest(recipePath: anonymous.path(percentEncoded: false)))
      }
      // `start` refused before anything was written, so only the first build has a row.
      #expect(try await harness.buildRows.list(states: nil).count == 1)
    }
  }

  @Test func readLogPagesTheTranscriptAndReportsCompletion() async throws {
    try await withBuildHarness { harness in
      try await harness.base.importLinuxImage()
      let recipe = try harness.writeRecipe("""
        FROM test-linux
        RUN /bin/echo paged

        """)
      let started = try await harness.builder.start(
        ImageBuildRequest(recipePath: recipe.path(percentEncoded: false), name: "paged"))
      let agent = try await harness.startBuildAgent(started.buildId)
      _ = try await harness.settle(started.buildId)
      await agent.stop()

      let first = try await harness.builder.readLog(id: started.buildId, offset: 0, maxBytes: 32)
      #expect(first.data.count == 32)
      #expect(!first.done)
      var offset = first.nextOffset
      var text = first.data
      while true {
        let chunk = try await harness.builder.readLog(
          id: started.buildId, offset: offset, maxBytes: 4_096)
        text += chunk.data
        offset = chunk.nextOffset
        if chunk.done { break }
      }
      #expect(text.contains("[stdout] step ok"))
    }
  }
}
