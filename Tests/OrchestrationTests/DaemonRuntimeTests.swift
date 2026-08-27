import ConfigLoader
import DaemonAPI
import Foundation
import GitHubControl
import Logging
import Metrics
import RunnerCore
import Testing

@testable import Orchestration

@Suite struct DaemonRuntimeTests {
  /// The maintenance loop probes the credential on its first, eager tick. Pointing the gateway at
  /// an in-process fake (and an empty keychain) keeps that off the network and off the
  /// developer's login keychain.
  private func makeRuntime(
    _ tree: TempTree, configPath: URL?, github: FakeGitHubServer = FakeGitHubServer(),
    demandMode: DemandMode? = nil, exitOnShutdown: Bool = true
  ) throws -> DaemonRuntime {
    DaemonRuntime(
      options: DaemonRuntime.Options(
        paths: tree.paths,
        configPath: configPath,
        // Long enough that the loop never fires twice during a test; the first tick is eager.
        reconcileInterval: .seconds(3_600),
        reconcileJitter: .zero,
        vmworkerPath: try tree.vmworkerStub(),
        actorName: "test",
        github: GitHubGateway.Options(
          paths: tree.paths, baseURL: github.baseURL, session: github.makeSession(),
          keychain: InMemoryKeychain()),
        demandMode: demandMode,
        shutdownDelay: .zero,
        exitOnShutdown: exitOnShutdown),
      parseConfig: { try ConfigLoader.load(yaml: $0) },
      logger: Logger(label: "test"))
  }

  private func withRunningDaemon(
    configPath: URL?,
    tree: TempTree,
    demandMode: DemandMode? = nil,
    exitOnShutdown: Bool = true,
    _ body: (DaemonRuntime, DaemonClient) async throws -> Void
  ) async throws {
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let runtime = try makeRuntime(
      tree, configPath: configPath, github: github, demandMode: demandMode,
      exitOnShutdown: exitOnShutdown)
    try await runtime.start()
    let client = try await DaemonClient.connect(socketPath: tree.paths.daemonSocket)
    do {
      try await body(runtime, client)
    } catch {
      await client.close()
      await runtime.stop()
      throw error
    }
    await client.close()
    await runtime.stop()
  }

  /// Phase 5 wiring: the builder exists, answers `build.*` (without one every method returns
  /// `BUILD_UNAVAILABLE`), owns the directories it needs, and is stopped as part of teardown.
  @Test func theImageBuilderIsWiredIntoTheRuntime() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree) { runtime, client in
      let builds = try await client.buildList()
      #expect(builds.builds.isEmpty)
      for directory in [tree.paths.buildsDir, tree.paths.buildLogsDir, tree.paths.buildSocketDir,
                        tree.paths.baseImageCacheDir] {
        #expect(
          FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
          "\(directory.lastPathComponent) must exist")
      }
      // The whole path daemon socket -> service -> builder, proven by an intake refusal that only
      // the builder itself can produce.
      var refusal: String?
      do {
        _ = try await client.imageBuild(
          ImageBuildRequest(recipePath: "/nonexistent/Runnerfile", name: "x"))
      } catch {
        refusal = "\(error)"
      }
      #expect(refusal?.contains("BUILD_RECIPE_UNREADABLE") == true, "got \(refusal ?? "success")")
      #expect(await runtime.isRunning)
    }
  }

  @Test func startAppliesTheConfigAndServesStatus() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree) { runtime, client in
      let status = try await client.status()
      #expect(status.daemon.state == .healthy)
      #expect(status.host.architecture == "arm64")
      #expect(status.host.logicalCPUCount == 12)
      #expect(status.host.probeSucceeded)
      #expect(!status.daemon.hostId.isEmpty)
      #expect(status.daemon.mode == "normal")
      #expect(Set(status.profiles.map(\.name)) == ["ubuntu-24"])
      #expect(status.github.scopeCount == 1)
      // The eager first tick runs before start() returns the socket to callers.
      #expect(status.reconciliation.runCount >= 1)
      #expect(await runtime.isRunning)
    }
  }

  @Test func demandProviderComesFromGitHubDemandInTheConfiguration() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let yaml = ExampleConfig.example.replacingOccurrences(
      of: "github:\n  auth:", with: "github:\n  demand: manual\n  auth:")
    let configPath = try tree.file("config.yaml", contents: yaml)

    try await withRunningDaemon(configPath: configPath, tree: tree) { _, client in
      let response = try await client.debugDemandSet(profile: "ubuntu-24", assignedJobs: 3)
      #expect(response.assignedJobs == 3)
    }
  }

  @Test func demandProviderDefaultsToScaleSetAndRejectsManualOverrides() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree) { _, client in
      do {
        _ = try await client.debugDemandSet(profile: "ubuntu-24", assignedJobs: 3)
        Issue.record("expected DEMAND_NOT_MANUAL")
      } catch let error as DaemonClientError {
        #expect(error.code == "DEMAND_NOT_MANUAL")
      }
    }
  }

  /// `Options.demandMode` is the test/CLI escape hatch and wins over whatever the configuration
  /// says, even though the applied document here defaults to `scaleSet`.
  @Test func optionsDemandModeOverridesTheConfiguration() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree, demandMode: .manual) {
      _, client in
      let response = try await client.debugDemandSet(profile: "ubuntu-24", assignedJobs: 7)
      #expect(response.assignedJobs == 7)
    }
  }

  /// The demand provider is wired once at startup and never hot-swapped (`Orchestrator` holds it
  /// as a `let`); reapplying a configuration that flips `github.demand` must not change which
  /// provider is live until the next restart.
  @Test func reapplyingADifferentDemandModeDoesNotHotSwapTheProvider() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)
    let manualYAML = ExampleConfig.example.replacingOccurrences(
      of: "github:\n  auth:", with: "github:\n  demand: manual\n  auth:")

    try await withRunningDaemon(configPath: configPath, tree: tree) { _, client in
      _ = try await client.configApply(yaml: manualYAML)
      do {
        _ = try await client.debugDemandSet(profile: "ubuntu-24", assignedJobs: 3)
        Issue.record("expected the still-scaleSet provider to reject a manual override")
      } catch let error as DaemonClientError {
        #expect(error.code == "DEMAND_NOT_MANUAL")
      }
    }
  }

  @Test func profileAndScopeListsComeFromTheDatabase() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree) { _, client in
      let profiles = try await client.profileList()
      #expect(profiles.profiles.map(\.name) == ["ubuntu-24"])
      #expect(profiles.profiles.allSatisfy { $0.scope == "engineering" })

      let ubuntu = try await client.profileGet(name: "ubuntu-24")
      #expect(ubuntu.cpuCount == 4)
      #expect(ubuntu.memoryBytes == 8 * 1_024 * 1_024 * 1_024)

      let scopes = try await client.scopeList()
      #expect(scopes.scopes.map(\.name) == ["engineering"])
      #expect(scopes.scopes[0].runnerGroup == "Default")
    }
  }

  @Test func configGetReturnsTheAppliedDocument() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)

    try await withRunningDaemon(configPath: configPath, tree: tree) { _, client in
      let response = try await client.configGet()
      #expect(response.yaml == ExampleConfig.example)
      #expect(response.appliedAt != nil)
      let version = try await client.version()
      #expect(version.schemaVersion == RunnerVMBuild.schemaVersion)
    }
  }

  @Test func validateOverTheSocketReportsIssues() async throws {
    let tree = try TempTree()
    defer { tree.remove() }

    try await withRunningDaemon(configPath: nil, tree: tree) { _, client in
      let good = try await client.configValidate(yaml: ExampleConfig.example)
      #expect(good.valid)

      let bad = try await client.configValidate(
        yaml: "version: 1\nprofiles:\n  - name: p\n    scope: nope\n    image: ghcr.io/a/b:1\n")
      #expect(!bad.valid)
      #expect(bad.issues.contains(code: "PROFILE_UNKNOWN_SCOPE"))
    }
  }

  @Test func applyOverTheSocketPersistsAcrossRestart() async throws {
    let tree = try TempTree()
    defer { tree.remove() }

    try await withRunningDaemon(configPath: nil, tree: tree) { _, client in
      let empty = try await client.configGet()
      #expect(empty.yaml == nil)
      let applied = try await client.configApply(yaml: ExampleConfig.example)
      #expect(applied.diff.addedScopes == ["engineering"])
      #expect(!applied.operationId.isEmpty)
      let operations = try await client.operationList()
      #expect(operations.operations.first?.kind == "apply-config")
    }

    // A second runtime over the same state directory adopts what the first applied.
    try await withRunningDaemon(configPath: nil, tree: tree) { _, client in
      let response = try await client.configGet()
      #expect(response.yaml == ExampleConfig.example)
      let status = try await client.status()
      #expect(status.profiles.count == 1)
      #expect(status.capacity.reservedCPUCount == 2)
    }
  }

  @Test func rejectedConfigurationAbortsStartup() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let broken = try tree.file(
      "config.yaml",
      contents: "version: 1\nprofiles:\n  - name: p\n    scope: nope\n    image: ghcr.io/a/b:1\n")
    let runtime = try makeRuntime(tree, configPath: broken)

    await #expect(throws: ConfigurationError.self) { try await runtime.start() }
    #expect(await !runtime.isRunning)
    // Startup released the lock, so a corrected run can start immediately.
    let lock = try DaemonLock.acquire(at: tree.paths.stateDir.appending(path: "runnerd.lock"))
    lock.release()
  }

  @Test func missingConfigFileAbortsStartupWithAReadableError() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let runtime = try makeRuntime(tree, configPath: tree.root.appending(path: "absent.yaml"))
    do {
      try await runtime.start()
      Issue.record("expected startup to fail")
    } catch let error as OrchestrationError {
      #expect(error.code == "CONFIG_FILE_UNREADABLE")
    }
  }

  @Test func aSecondRuntimeOnTheSameStateDirectoryIsRefused() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let first = try makeRuntime(tree, configPath: nil)
    try await first.start()
    defer { Task { await first.stop() } }

    let second = try makeRuntime(tree, configPath: nil)
    do {
      try await second.start()
      Issue.record("expected the single-daemon lock to refuse a second runtime")
    } catch let error as OrchestrationError {
      #expect(error.code == "DAEMON_ALREADY_RUNNING")
    }
    await first.stop()
  }

  @Test func stopRemovesTheSocketAndReleasesTheLock() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let runtime = try makeRuntime(tree, configPath: nil)
    try await runtime.start()
    #expect(FileManager.default.fileExists(atPath: tree.paths.daemonSocket.path))
    await runtime.stop()
    #expect(await !runtime.isRunning)

    let lock = try DaemonLock.acquire(at: tree.paths.stateDir.appending(path: "runnerd.lock"))
    lock.release()
  }

  @Test func unimplementedMethodsAnswerNotImplementedOverTheRealDaemon() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    try await withRunningDaemon(configPath: nil, tree: tree) { _, client in
      do {
        _ = try await client.callRaw(.systemDoctor)
        Issue.record("system.doctor should not be implemented yet")
      } catch let error as DaemonClientError {
        #expect(error.code == DaemonErrorCode.notImplemented)
      }
    }
  }
}


/// M13: host mode, the metrics endpoint and shutdown, driven through the real composition root.
@Suite struct RuntimeSystemTests {
  private func tree() throws -> TempTree { try TempTree() }

  /// `metrics.prometheus.listen` is validated to a real port range, so port 0 is not an option in
  /// a configuration document: bind one ephemerally, note it, and hand it to the daemon.
  private func freeLoopbackPort() async throws -> UInt16 {
    let probe = try MetricsEndpoint(
      listen: "127.0.0.1:0", snapshot: { MetricsSnapshot(collectedAt: "", families: []) })
    try await probe.start()
    let port = try #require(await probe.port())
    await probe.stop()
    return port
  }

  private func runtime(
    _ tree: TempTree, configPath: URL, github: FakeGitHubServer
  ) throws -> DaemonRuntime {
    DaemonRuntime(
      options: DaemonRuntime.Options(
        paths: tree.paths,
        configPath: configPath,
        reconcileInterval: .seconds(3_600),
        reconcileJitter: .zero,
        vmworkerPath: try tree.vmworkerStub(),
        actorName: "test",
        github: GitHubGateway.Options(
          paths: tree.paths, baseURL: github.baseURL, session: github.makeSession(),
          keychain: InMemoryKeychain()),
        shutdownDelay: .zero,
        exitOnShutdown: false),
      parseConfig: { try ConfigLoader.load(yaml: $0) },
      logger: Logger(label: "test"))
  }

  /// Spec §108: the reply comes back before the socket goes away, and the runtime is down by the
  /// time the shutdown task finishes.
  @Test func shutdownForceStopsTheRuntime() async throws {
    let tree = try tree()
    defer { tree.remove() }
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)
    let runtime = try runtime(tree, configPath: configPath, github: github)
    try await runtime.start()

    let client = try await DaemonClient.connect(socketPath: tree.paths.daemonSocket)
    let drained = try await client.systemDrain()
    #expect(drained.mode == "draining")
    let response = try await client.systemShutdown(force: true)
    #expect(response.accepted)
    await client.close()

    await runtime.awaitShutdown()
    #expect(await runtime.isRunning == false)
  }

  @Test func drainAndResumeAreVisibleInStatus() async throws {
    let tree = try tree()
    defer { tree.remove() }
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)
    let runtime = try runtime(tree, configPath: configPath, github: github)
    try await runtime.start()
    let client = try await DaemonClient.connect(socketPath: tree.paths.daemonSocket)

    _ = try await client.systemDrain()
    #expect(try await client.status().daemon.mode == "draining")
    _ = try await client.systemOffline()
    #expect(try await client.status().daemon.mode == "offline")
    _ = try await client.systemResume()
    let status = try await client.status()
    #expect(status.daemon.mode == "normal")
    #expect(status.daemon.activeSessions == 0)

    await client.close()
    await runtime.stop()
  }

  /// Spec §43: off by default, and only started when the applied document turns it on.
  @Test func thePrometheusEndpointIsDisabledUnlessTheConfigurationEnablesIt() async throws {
    let tree = try tree()
    defer { tree.remove() }
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let configPath = try tree.file("config.yaml", contents: ExampleConfig.example)
    let runtime = try runtime(tree, configPath: configPath, github: github)
    try await runtime.start()

    #expect(await runtime.metricsPort() == nil)

    await runtime.stop()
  }

  @Test func thePrometheusEndpointServesTheDaemonRegistryWhenEnabled() async throws {
    let tree = try tree()
    defer { tree.remove() }
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let chosen = try await freeLoopbackPort()
    let yaml = ExampleConfig.example.replacingOccurrences(
      of: "metrics:\n  prometheus:\n    enabled: false",
      with: "metrics:\n  prometheus:\n    enabled: true\n    listen: 127.0.0.1:\(chosen)")
    let configPath = try tree.file("config.yaml", contents: yaml)
    let runtime = try runtime(tree, configPath: configPath, github: github)
    try await runtime.start()
    #expect(await runtime.metricsPort() == chosen)

    let url = try #require(URL(string: "http://127.0.0.1:\(chosen)/metrics"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    let (data, response) = try await URLSession(configuration: configuration).data(from: url)
    let body = String(decoding: data, as: UTF8.self)

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(body.contains("# TYPE runnervm_job_duration_seconds histogram"))
    #expect(body.contains("# HELP runnervm_worker_rss_bytes"))

    await runtime.stop()
  }

  /// A daemon that would put its metrics on a LAN must not start at all.
  @Test func aNonLoopbackListenAddressStopsStartup() async throws {
    let tree = try tree()
    defer { tree.remove() }
    let github = FakeGitHubServer()
    defer { github.shutdown() }
    let yaml = ExampleConfig.example.replacingOccurrences(
      of: "metrics:\n  prometheus:\n    enabled: false",
      with: "metrics:\n  prometheus:\n    enabled: true\n    listen: 0.0.0.0:9095")
    let configPath = try tree.file("config.yaml", contents: yaml)
    let runtime = try runtime(tree, configPath: configPath, github: github)

    await #expect(throws: ConfigurationError.self) { try await runtime.start() }
    #expect(await runtime.isRunning == false)
  }
}
