import Foundation
import RPC
import RunnerCore
import Testing

@testable import DaemonAPI

@Suite struct BuildMethodCatalogueTests {
  @Test func theFiveBuildMethodsAreCataloguedAndImplemented() {
    let methods: [DaemonMethod] = [.imageBuild, .buildList, .buildGet, .buildLog, .buildCancel]
    for method in methods {
      #expect(DaemonMethod.allCases.contains(method), "\(method)")
      #expect(method.isImplemented, "\(method)")
    }
  }

  @Test func methodClassesMatchTheirRetrySafety() {
    #expect(DaemonMethod.imageBuild.methodClass == .singleShot)
    #expect(DaemonMethod.buildList.methodClass == .readOnly)
    #expect(DaemonMethod.buildGet.methodClass == .readOnly)
    #expect(DaemonMethod.buildLog.methodClass == .readOnly)
    #expect(DaemonMethod.buildCancel.methodClass == .idempotentMutation)
  }

  @Test func rawValuesMatchTheProtocolDocument() {
    #expect(DaemonMethod.imageBuild.rawValue == "image.build")
    #expect(DaemonMethod.buildList.rawValue == "build.list")
    #expect(DaemonMethod.buildGet.rawValue == "build.get")
    #expect(DaemonMethod.buildLog.rawValue == "build.log")
    #expect(DaemonMethod.buildCancel.rawValue == "build.cancel")
  }
}

@Suite struct BuildDTORoundTripTests {
  private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  @Test func imageBuildRequestDecodesWithOnlyRecipePath() throws {
    let request = try Self.decode(ImageBuildRequest.self, """
      {"recipePath": "/tmp/Runnerfile"}
      """)
    #expect(request.recipePath == "/tmp/Runnerfile")
    #expect(request.contextPath == nil)
    #expect(request.name == nil)
    #expect(request.args.isEmpty)
    #expect(request.push == nil)
    #expect(request.cpus == nil)
    #expect(request.noCache == false)
  }

  @Test func imageBuildRequestToleratesUnknownKeys() throws {
    let request = try Self.decode(ImageBuildRequest.self, """
      {"recipePath": "/tmp/Runnerfile", "somethingNew": 42}
      """)
    #expect(request.recipePath == "/tmp/Runnerfile")
  }

  @Test func imageBuildRequestReadsEveryField() throws {
    let request = try Self.decode(ImageBuildRequest.self, """
      {
        "recipePath": "/tmp/Runnerfile", "contextPath": "/tmp/ctx", "name": "ubuntu-24-docker",
        "args": {"VERSION": "24.04"}, "push": "ghcr.io/acme/ubuntu-24:latest", "cpus": 4,
        "memoryBytes": 4294967296, "diskBytes": 17179869184, "timeoutMs": 3600000, "noCache": true
      }
      """)
    #expect(request.contextPath == "/tmp/ctx")
    #expect(request.name == "ubuntu-24-docker")
    #expect(request.args == ["VERSION": "24.04"])
    #expect(request.push == "ghcr.io/acme/ubuntu-24:latest")
    #expect(request.cpus == 4)
    #expect(request.memoryBytes == 4_294_967_296)
    #expect(request.diskBytes == 17_179_869_184)
    #expect(request.timeoutMs == 3_600_000)
    #expect(request.noCache)
  }

  @Test func imageBuildRequestRoundTrips() throws {
    let request = ImageBuildRequest(
      recipePath: "/tmp/Runnerfile", contextPath: "/tmp/ctx", name: "app",
      args: ["A": "1"], push: "ghcr.io/acme/app:latest", cpus: 2, memoryBytes: 1 << 30,
      diskBytes: 1 << 34, timeoutMs: 1_000, noCache: true)
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(ImageBuildRequest.self, from: data) == request)
  }

  @Test func buildLogRequestDefaultsOffsetToZero() {
    let request = BuildLogRequest(buildId: "build-1")
    #expect(request.offset == 0)
    #expect(request.maxBytes == nil)
  }

  @Test func buildLogRequestMaxChunkBytesIsTheWireCeiling() {
    #expect(BuildLogRequest.maxChunkBytes == 262_144)
  }

  @Test func buildInfoDTORoundTrips() throws {
    let info = BuildInfoDTO(
      buildId: "build-1", name: "app", state: "queued", operationId: "op-1",
      pushReference: "ghcr.io/acme/app:latest", pushOperationId: "op-2", recipePath: "/tmp/Runnerfile",
      recipeSHA256: String(repeating: "a", count: 64), contextPath: "/tmp/ctx",
      contextSHA256: String(repeating: "b", count: 64), fromKind: "image", fromReference: "ubuntu-24",
      baseDigest: "sha256:" + String(repeating: "c", count: 64), baseSHA256: nil, cpuCount: 4,
      memoryBytes: 1 << 30, diskBytes: 1 << 34, diskReservationBytes: 1 << 34, timeoutMs: 3_600_000,
      buildPath: "/var/lib/runnervm/builds/build-1", logPath: "/var/lib/runnervm/logs/builds/build-1/build.log",
      workerPid: 4_242, totalSteps: 3, currentStep: 1, currentInstruction: "RUN apt-get update",
      imageDigest: nil, failureCode: nil, failureMessage: nil, createdAt: "2026-01-01T00:00:00.000Z",
      startedAt: "2026-01-01T00:00:01.000Z", finishedAt: nil, updatedAt: "2026-01-01T00:00:02.000Z")
    let data = try JSONEncoder().encode(info)
    #expect(try JSONDecoder().decode(BuildInfoDTO.self, from: data) == info)
  }

  @Test func buildCancelResponseRoundTrips() throws {
    let response = BuildCancelResponse(buildId: "build-1", state: "cancelled")
    let data = try JSONEncoder().encode(response)
    #expect(try JSONDecoder().decode(BuildCancelResponse.self, from: data) == response)
  }
}

/// `SystemStatus.builds` (Phase 6): optional for wire compat with a daemon that predates the
/// image builder.
@Suite struct SystemStatusBuildsDTOTests {
  @Test func roundTripsWithBuilds() throws {
    let status = sampleStatus()
    var withBuilds = status
    withBuilds.builds = BuildsSummary(running: 2, queued: 1)
    let data = try JSONEncoder().encode(withBuilds)
    let decoded = try JSONDecoder().decode(SystemStatus.self, from: data)
    #expect(decoded == withBuilds)
    #expect(decoded.builds == BuildsSummary(running: 2, queued: 1))
  }

  @Test func decodesAsNilWhenTheKeyIsAbsent() throws {
    // A pre-Phase-6 daemon's JSON simply has no "builds" key at all -- not `null`.
    let json = """
      {
        "daemon": {"state": "healthy", "version": "1.2.3", "pid": 1, "hostId": "h",
          "mode": "normal", "startedAt": "2026-01-01T00:00:00.000Z", "uptimeSeconds": 1,
          "activeSessions": 0},
        "host": {"osVersion": "15.0", "architecture": "arm64", "logicalCPUCount": 1,
          "physicalMemoryBytes": 1, "freeDiskBytes": 1, "virtualizationSupported": true,
          "nestedVirtualizationSupported": false, "macOSGuestLimit": 1, "probeSucceeded": true},
        "capacity": {"runningVMs": 0, "maxVMs": null, "reservedCPUCount": 0,
          "reservedMemoryBytes": 0, "reservedDiskBytes": 0, "placeholder": false},
        "github": {"authState": "unconfigured", "scopeCount": 0, "scopesHealthy": 0,
          "scaleSetsHealthy": 0, "placeholder": false},
        "images": {"cached": 0, "diskUsageBytes": 0, "pulling": 0, "runnerStale": 0,
          "runnerTooOld": 0},
        "profiles": [],
        "reconciliation": {"runCount": 0, "errorCount": 0, "instanceCount": 0, "workerCount": 0,
          "orphanCount": 0},
        "diskPressure": {"freeBytes": 1, "floorBytes": 0, "state": "ok"}
      }
      """
    let status = try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
    #expect(status.builds == nil)
  }

  @Test func defaultInitLeavesBuildsNil() {
    #expect(sampleStatus().builds == nil)
  }
}
