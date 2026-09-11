import Foundation
import Logging
import ProcessSpawn
import RunnerCore
import RunnerLogging

/// Host facts plus the extras `system.status` reports. `probeSucceeded == false` means the values
/// came from the `ProcessInfo` fallback below and no Virtualization limit is authoritative.
public struct HostProbeResult: Sendable, Hashable {
  public var facts: HostFacts
  public var architecture: String
  public var osVersion: String
  public var virtualizationSupported: Bool
  public var nestedVirtualizationSupported: Bool
  public var macOSGuestLimit: Int
  public var probeSucceeded: Bool
  public var failureReason: String?
  /// The probe was spawned and had to be killed, as opposed to being missing or unsigned. The
  /// maintenance loop re-runs a timed-out probe rather than leaving the daemon reporting
  /// `virtualizationSupported: false` for the rest of its life.
  public var probeTimedOut: Bool = false
}

/// Mirror of `VirtualizationCore.HostCapabilities`, redeclared here because runnerd must never
/// link Virtualization.framework (spec §7.2). Field names are the wire contract with
/// `vmworker probe`.
struct ProbedHostCapabilities: Codable, Sendable {
  var virtualizationSupported: Bool
  var architecture: String
  var hostOSVersion: String
  var logicalCPUCount: Int
  var physicalMemoryBytes: UInt64
  var minimumAllowedCPUCount: Int
  var maximumAllowedCPUCount: Int
  var minimumAllowedMemoryBytes: UInt64
  var maximumAllowedMemoryBytes: UInt64
  var nestedVirtualizationSupported: Bool
  var macOSGuestLimit: Int
}

/// Runs the signed `vmworker probe` helper and turns its JSON into `HostFacts`.
public enum HostProbe {
  /// Overrides the sibling-of-runnerd lookup; the end-to-end tests point this at a stub script.
  public static let executableOverrideVariable = "RUNNERVM_VMWORKER"

  /// Wall-clock ceiling on one `vmworker probe`. `run` is awaited before runnerd binds its socket
  /// and opens its database, so an unbounded probe is an unbounded — and silent — startup hang.
  public static let defaultDeadline: Duration = .seconds(60)

  /// Grace between the deadline's `SIGTERM` and the `SIGKILL` that follows it.
  private static let killGrace: TimeInterval = 5

  /// How long the probe's pipes are still read after its leader exits. A probe writes one small
  /// JSON document, so this only ever covers a helper that forked something before dying.
  private static let drainGrace: Duration = .seconds(2)

  public static func defaultExecutable() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment[executableOverrideVariable], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    guard let ownExecutable = Bundle.main.executableURL ?? Self.executableFromArgv() else {
      return nil
    }
    return ownExecutable.deletingLastPathComponent().appending(path: "vmworker")
  }

  private static func executableFromArgv() -> URL? {
    guard let argv0 = CommandLine.arguments.first, argv0.contains("/") else { return nil }
    return URL(fileURLWithPath: argv0).standardizedFileURL
  }

  /// Never throws: a missing or unsigned helper degrades to `ProcessInfo` facts so a developer
  /// can run `runnerd --foreground` without a code-signing step.
  public static func run(
    executable: URL?, logger: Logger, deadline: Duration = defaultDeadline
  ) async -> HostProbeResult {
    guard let executable else {
      return fallback(reason: "no vmworker executable found", logger: logger)
    }
    switch await invoke(executable, deadline: deadline) {
    case .success(let capabilities):
      return result(from: capabilities)
    case .timedOut:
      // Deliberately its own log line: a wedged helper is a different host problem from a missing
      // or unsigned one, and the two used to be indistinguishable in the daemon's startup log.
      let limit = seconds(deadline)
      logger.warning(
        "vmworker probe timed out; using fallback host facts",
        metadata: ["timeout_seconds": .stringConvertible(limit)])
      return fallbackResult(reason: "vmworker probe timed out after \(limit)s", timedOut: true)
    case .failure(let reason):
      return fallback(reason: reason, logger: logger)
    }
  }

  // MARK: - Subprocess

  private enum Outcome: Sendable {
    case success(ProbedHostCapabilities)
    case failure(String)
    case timedOut
  }

  /// One `vmworker probe`, through the shared `posix_spawn` runner: an explicit environment, both
  /// pipes drained concurrently against a deadline (a probe that fills the 64 KiB stderr buffer
  /// first would deadlock a stdout-to-EOF reader), `SIGTERM` at the deadline and `SIGKILL`
  /// `killGrace` later against the probe's whole process group, and a decoded exit code.
  private static func invoke(_ executable: URL, deadline: Duration) async -> Outcome {
    let path = executable.path(percentEncoded: false)
    let result: SpawnResult
    do {
      result = try await ProcessSpawn.run(
        SpawnRequest(
          executable: path, arguments: ["probe", "--json"], timeout: deadline,
          killGrace: .seconds(killGrace), drainGrace: drainGrace))
    } catch let error as SpawnError {
      if case .executableMissing = error { return .failure("\(path) is not executable") }
      return .failure("cannot spawn vmworker probe: \(error)")
    } catch {
      return .failure("cannot spawn vmworker probe: \(error)")
    }
    guard !result.timedOut else { return .timedOut }
    guard result.exitCode == 0 else {
      let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return .failure("vmworker probe exited \(result.exitCode): \(detail)")
    }
    do {
      return .success(
        try JSONDecoder().decode(ProbedHostCapabilities.self, from: Data(result.stdout.utf8)))
    } catch {
      return .failure("vmworker probe emitted unreadable JSON: \(error)")
    }
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }

  // MARK: - Mapping

  private static func result(from capabilities: ProbedHostCapabilities) -> HostProbeResult {
    HostProbeResult(
      facts: HostFacts(
        logicalCPUCount: capabilities.logicalCPUCount,
        physicalMemoryBytes: capabilities.physicalMemoryBytes,
        minimumAllowedCPUCount: capabilities.minimumAllowedCPUCount,
        maximumAllowedCPUCount: capabilities.maximumAllowedCPUCount,
        minimumAllowedMemoryBytes: capabilities.minimumAllowedMemoryBytes,
        maximumAllowedMemoryBytes: capabilities.maximumAllowedMemoryBytes),
      architecture: capabilities.architecture,
      osVersion: capabilities.hostOSVersion,
      virtualizationSupported: capabilities.virtualizationSupported,
      nestedVirtualizationSupported: capabilities.nestedVirtualizationSupported,
      macOSGuestLimit: capabilities.macOSGuestLimit,
      probeSucceeded: true)
  }

  private static func fallback(reason: String, logger: Logger) -> HostProbeResult {
    logger.warning(
      "host probe unavailable; falling back to ProcessInfo facts",
      metadata: ["reason": .string(reason)])
    return fallbackResult(reason: reason)
  }

  /// The fallback facts without the log line: the timeout path above logs its own.
  private static func fallbackResult(reason: String, timedOut: Bool = false) -> HostProbeResult {
    let info = ProcessInfo.processInfo
    let os = info.operatingSystemVersion
    return HostProbeResult(
      facts: HostFacts(
        logicalCPUCount: info.activeProcessorCount,
        physicalMemoryBytes: info.physicalMemory,
        minimumAllowedCPUCount: 1,
        maximumAllowedCPUCount: info.activeProcessorCount,
        minimumAllowedMemoryBytes: ByteSize.mebibytes(128).bytes,
        maximumAllowedMemoryBytes: info.physicalMemory),
      architecture: machineArchitecture(),
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      virtualizationSupported: false,
      nestedVirtualizationSupported: false,
      macOSGuestLimit: HostConstants.macOSGuestLimit,
      probeSucceeded: false,
      failureReason: reason,
      probeTimedOut: timedOut)
  }

  private static func machineArchitecture() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    return String(cString: buffer)
  }
}
