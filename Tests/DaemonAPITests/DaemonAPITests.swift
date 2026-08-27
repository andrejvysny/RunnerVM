import Foundation
import RPC
import RunnerCore
import Testing

@testable import DaemonAPI

@Suite struct DaemonMethodCatalogueTests {
  @Test func everyCatalogueMethodHasAUniqueName() {
    let names = Set(DaemonMethod.allCases.map(\.rawValue))
    #expect(names.count == DaemonMethod.allCases.count)
  }

  @Test func mutationsAreNotClassifiedReadOnly() {
    for method in [
      DaemonMethod.configApply, .systemReconcile, .systemDrain, .systemResume, .systemOffline,
      .systemShutdown, .instanceStop,
    ] {
      #expect(method.methodClass != .readOnly)
    }
    #expect(DaemonMethod.systemStatus.methodClass == .readOnly)
    #expect(DaemonMethod.instanceCreate.methodClass == .singleShot)
  }

  @Test func implementedSubsetIsPartOfTheCatalogue() {
    #expect(DaemonMethod.implemented.isSubset(of: Set(DaemonMethod.allCases)))
    #expect(DaemonMethod.systemStatus.isImplemented)
    #expect(DaemonMethod.imageList.isImplemented)
    #expect(DaemonMethod.imagePrune.isImplemented)
    #expect(DaemonMethod.runnerList.isImplemented)
    #expect(DaemonMethod.scaleSetList.isImplemented)
    #expect(DaemonMethod.debugDemandSet.isImplemented)
    #expect(DaemonMethod.authLogin.isImplemented)
    #expect(DaemonMethod.metricsSnapshot.isImplemented)
    #expect(DaemonMethod.systemDrain.isImplemented)
    #expect(DaemonMethod.systemShutdown.isImplemented)
    #expect(!DaemonMethod.logsTail.isImplemented)
  }
}

@Suite struct ConfigDiffTests {
  @Test func emptyDiffReportsNoChanges() {
    #expect(ConfigDiff().isEmpty)
    #expect(ConfigDiff().changeCount == 0)
  }

  @Test func changeCountSumsEverySection() {
    let diff = ConfigDiff(
      addedScopes: ["a"], updatedScopes: ["b"], disabledProfiles: ["c", "d"])
    #expect(!diff.isEmpty)
    #expect(diff.changeCount == 4)
  }
}

/// Server and client are the real ones; only the service is a fake.
@Suite struct DaemonTransportTests {
  private func withDaemon(
    _ body: (DaemonClient, FakeDaemonService) async throws -> Void
  ) async throws {
    let socket = try makeSocketPath()
    defer { removeSocketDirectory(socket) }
    let service = FakeDaemonService()
    let server = DaemonServer(service: service, socketPath: socket)
    try await server.start()
    let client = try await DaemonClient.connect(socketPath: socket)
    do {
      try await body(client, service)
    } catch {
      await client.close()
      await server.stop()
      throw error
    }
    await client.close()
    await server.stop()
  }

  @Test func scaleSetListRoundTripsSessionAndDemand() async throws {
    try await withDaemon { client, service in
      await service.setScaleSets([
        ScaleSetSummary(
          profile: "ubuntu-24", name: "runnervm-ubuntu-24", githubScaleSetId: 42, state: "ready",
          sessionState: "open", sessionGeneration: 3, lastMessageId: 17, advertisedCapacity: 4,
          assignedJobs: 2, healthy: true,
          statistics: ScaleSetStatisticsDTO(totalAssignedJobs: 2, totalIdleRunners: 1),
          updatedAt: "2026-01-01T00:00:00.000Z"),
      ])
      let response = try await client.scaleSetList()
      #expect(response.scaleSets.count == 1)
      #expect(response.scaleSets.first?.name == "runnervm-ubuntu-24")
      #expect(response.scaleSets.first?.sessionGeneration == 3)
      #expect(response.scaleSets.first?.lastMessageId == 17)
      #expect(response.scaleSets.first?.advertisedCapacity == 4)
      #expect(response.scaleSets.first?.statistics?.totalAssignedJobs == 2)
    }
  }

  @Test func debugDemandSetCarriesTheProfileAndCount() async throws {
    try await withDaemon { client, service in
      let response = try await client.debugDemandSet(profile: "ubuntu-24", assignedJobs: 5)
      #expect(response.assignedJobs == 5)
      #expect(await service.demandRequest()?.profile == "ubuntu-24")
      #expect(await service.demandRequest()?.assignedJobs == 5)
    }
  }

  @Test func statusRoundTripsEveryField() async throws {
    try await withDaemon { client, _ in
      let status = try await client.status()
      #expect(status == sampleStatus())
      #expect(status.daemon.uptimeSeconds == 61)
      #expect(status.host.physicalMemoryBytes == 68_719_476_736)
      #expect(status.profiles.first?.name == "ubuntu-24")
      #expect(status.diskPressure.state == "ok")
      #expect(status.diskPressure.floorBytes == 53_687_091_200)
    }
  }

  /// Spec §53: the freshness verdict is graded daemon-side, so it has to survive the wire.
  @Test func imageDTOCarriesTheRunnerVersionAndItsHealth() async throws {
    try await withDaemon { client, _ in
      let image = try await client.imageImport(
        ImageImportRequest(path: "/tmp/disk.img", os: "linux", name: "ubuntu-24"))
      #expect(image.runnerVersion == "2.320.0")
      #expect(image.runnerVersionHealth == .stale)
      #expect(image == FakeDaemonService.sampleImage(name: "ubuntu-24", os: "linux"))
    }
  }

  /// An older payload with neither field still decodes: both carry a default.
  @Test func imageDTODefaultsTheRunnerFieldsWhenAbsent() throws {
    let json = """
    {"digest":"sha256:a","os":"linux","architecture":"arm64","state":"ready",
     "virtualSizeBytes":1,"allocatedSizeBytes":1,"localPath":"/tmp/x","pinCount":0,
     "createdAt":"2026-01-01T00:00:00.000Z","runnerVersionHealth":"unknown"}
    """
    let decoded = try JSONDecoder().decode(ImageInfoDTO.self, from: Data(json.utf8))
    #expect(decoded.runnerVersion == nil)
    #expect(decoded.runnerVersionHealth == .unknown)
    // Appended later still (spec §58); a daemon that predates them says nothing rather than
    // guessing that the image is a native, agent-carrying one.
    #expect(decoded.sourceFormat == nil)
    #expect(decoded.guestAgent == nil)
  }

  @Test func imagePruneRoundTripsAndCarriesDryRun() async throws {
    try await withDaemon { client, service in
      let response = try await client.imagePrune(dryRun: true)
      #expect(response.candidates.count == 1)
      #expect(response.deleted.isEmpty)
      #expect(response.reclaimedBytes == 0)
      let seen = await service.lastPruneRequest
      #expect(seen?.dryRun == true)

      let real = try await client.imagePrune(dryRun: false)
      #expect(real.deleted.count == 1)
      #expect(real.reclaimedBytes == 2_000_000_000)
    }
  }

  @Test func versionRoundTrips() async throws {
    try await withDaemon { client, _ in
      let version = try await client.version()
      #expect(version.version == "1.2.3")
      #expect(version.protocolVersion == 1)
    }
  }

  @Test func validateCarriesIssuesBackToTheCaller() async throws {
    try await withDaemon { client, service in
      await service.setValidateIssues([
        .error("PROFILE_UNKNOWN_SCOPE", "profiles[0].scope", "unknown scope 'nope'"),
        .warning("GITHUB_NO_SCOPES", "github.scopes", "no GitHub scopes configured"),
      ])
      let response = try await client.configValidate(yaml: "version: 1\n")
      #expect(response.valid == false)
      #expect(response.issues.count == 2)
      #expect(response.issues.contains(code: "PROFILE_UNKNOWN_SCOPE"))
      let seen = await service.validatedYAML()
      #expect(seen == "version: 1\n")
    }
  }

  @Test func validateReportsValidWhenOnlyWarnings() async throws {
    try await withDaemon { client, service in
      await service.setValidateIssues([
        .warning("PROFILES_EMPTY", "profiles", "no runner profiles configured")
      ])
      let response = try await client.configValidate(yaml: "version: 1\n")
      #expect(response.valid)
    }
  }

  @Test func applyReturnsDiffAndOperationId() async throws {
    try await withDaemon { client, service in
      let response = try await client.configApply(yaml: "version: 1\n")
      #expect(response.operationId == "op-1")
      #expect(response.diff.addedProfiles == ["ubuntu-24"])
      let seen = await service.appliedYAML()
      #expect(seen == "version: 1\n")
    }
  }

  @Test func profileAndScopeLookupsRoundTrip() async throws {
    try await withDaemon { client, service in
      await service.setProfiles([
        ProfileSummary(
          name: "ubuntu-24", scope: "engineering", image: "ghcr.io/acme/u:stable",
          guestOS: "linux", lifecycle: "ephemeral", cpuCount: 4, memoryBytes: 8_589_934_592,
          diskBytes: 85_899_345_920, minIdle: 0, maxIdle: 0, maxInstances: 4, sshEnabled: true,
          enabled: true, updatedAt: "2026-01-01T00:00:00.000Z")
      ])
      await service.setScopes([
        ScopeSummary(
          name: "engineering", kind: "organization", owner: "acme", runnerGroup: "Default",
          enabled: true, health: "unknown", updatedAt: "2026-01-01T00:00:00.000Z")
      ])
      let listed = try await client.profileList()
      #expect(listed.profiles.count == 1)
      let profile = try await client.profileGet(name: "ubuntu-24")
      #expect(profile.cpuCount == 4)
      let scopeList = try await client.scopeList()
      #expect(scopeList.scopes.first?.slug == "acme")
      let scope = try await client.scopeGet(name: "engineering")
      #expect(scope.runnerGroup == "Default")
    }
  }

  @Test func missingProfileIsReportedAsNotFound() async throws {
    try await withDaemon { client, _ in
      await #expect(throws: DaemonClientError.self) {
        _ = try await client.profileGet(name: "absent")
      }
      do {
        _ = try await client.profileGet(name: "absent")
      } catch let error as DaemonClientError {
        #expect(error.code == DaemonErrorCode.notFound)
      }
    }
  }

  @Test func catalogueMethodsWithoutHandlersAnswerNotImplemented() async throws {
    try await withDaemon { client, _ in
      for method in [DaemonMethod.logsTail, .systemDoctor, .systemReconcile] {
        do {
          _ = try await client.callRaw(method)
          Issue.record("\(method.rawValue) should not be implemented yet")
        } catch let error as DaemonClientError {
          #expect(error.code == DaemonErrorCode.notImplemented)
        }
      }
    }
  }

  // MARK: - M13: host mode and metrics

  @Test func drainResumeAndOfflineRoundTripTheMode() async throws {
    try await withDaemon { client, service in
      let drained = try await client.systemDrain()
      #expect(drained.mode == "draining")
      #expect(drained.activeSessions == 2)
      #expect(await service.drainRequest()?.wait == false)

      #expect(try await client.systemOffline().mode == "offline")
      #expect(try await client.systemResume().mode == "normal")
      #expect(await service.currentMode() == "normal")
    }
  }

  @Test func drainWithWaitCarriesTheTimeoutAndReportsDrained() async throws {
    try await withDaemon { client, service in
      let response = try await client.systemDrain(wait: true, timeoutMs: 5_000)

      #expect(response.drained)
      #expect(response.activeSessions == 0)
      #expect(await service.drainRequest()?.wait == true)
      #expect(await service.drainRequest()?.timeoutMs == 5_000)
    }
  }

  /// Spec §108: without `--force` an active job is a refusal, not an interruption.
  @Test func shutdownWithoutForceIsRefusedWhileJobsRun() async throws {
    try await withDaemon { client, service in
      do {
        _ = try await client.systemShutdown(force: false)
        Issue.record("shutdown should be refused while sessions are active")
      } catch let error as DaemonClientError {
        #expect(error.code == "UNAVAILABLE")
      }

      let forced = try await client.systemShutdown(force: true)
      #expect(forced.accepted)
      #expect(await service.shutdownRequest()?.force == true)
    }
  }

  @Test func metricsSnapshotRoundTripsFamiliesAndPrometheusText() async throws {
    try await withDaemon { client, _ in
      let json = try await client.metricsSnapshot()
      let family = try #require(json.family("runnervm_sessions_total"))
      #expect(family.type == "counter")
      #expect(family.samples.first?.label("result") == "completed")
      #expect(family.samples.first?.value == 4)
      #expect(json.prometheus == nil)

      let text = try await client.metricsSnapshot(format: .prometheus)
      #expect(text.prometheus?.contains("# TYPE runnervm_sessions_total counter") == true)
    }
  }

  @Test func malformedPayloadIsRejectedAsInvalidParams() async throws {
    try await withDaemon { client, _ in
      do {
        // config.validate requires `yaml`; an empty object cannot decode.
        _ = try await client.callRaw(.configValidate, payload: .object([:]))
        Issue.record("expected INVALID_PARAMS")
      } catch let error as DaemonClientError {
        #expect(error.code == RPCErrorCode.invalidParams.rawValue)
      }
    }
  }

  @Test func unknownMethodNamesAreRejected() async throws {
    let socket = try makeSocketPath()
    defer { removeSocketDirectory(socket) }
    let server = DaemonServer(service: FakeDaemonService(), socketPath: socket)
    try await server.start()
    let raw = try await RPCClient.connect(protocol: .daemon, socketPath: socket)
    do {
      _ = try await raw.call(method: "config.teleport")
      Issue.record("expected UNKNOWN_METHOD")
    } catch let error as RPCCallError {
      #expect(error.payload?.code == RPCErrorCode.unknownMethod.rawValue)
    }
    await raw.close()
    await server.stop()
  }

  @Test func connectingToAnAbsentSocketIsUnreachable() async throws {
    let socket = URL(fileURLWithPath: "/tmp/rvm-api-missing-\(UUID().uuidString.prefix(8)).sock")
    do {
      _ = try await DaemonClient.connect(socketPath: socket)
      Issue.record("expected an unreachable error")
    } catch let error as DaemonClientError {
      #expect(error.isUnreachable)
      #expect(error.code == "DAEMON_UNREACHABLE")
    }
  }
}
