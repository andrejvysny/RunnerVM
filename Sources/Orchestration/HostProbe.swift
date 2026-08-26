import Foundation
import Logging
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
  public static func run(executable: URL?, logger: Logger) async -> HostProbeResult {
    guard let executable else {
      return fallback(reason: "no vmworker executable found", logger: logger)
    }
    let outcome = await Task.detached { Self.invoke(executable) }.value
    switch outcome {
    case .success(let capabilities):
      return result(from: capabilities)
    case .failure(let reason):
      return fallback(reason: reason, logger: logger)
    }
  }

  // MARK: - Subprocess

  private enum Outcome: Sendable {
    case success(ProbedHostCapabilities)
    case failure(String)
  }

  private static func invoke(_ executable: URL) -> Outcome {
    guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
      return .failure("\(executable.path(percentEncoded: false)) is not executable")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["probe", "--json"]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
    } catch {
      return .failure("cannot spawn vmworker probe: \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
      return .failure("vmworker probe exited \(process.terminationStatus): \(detail)")
    }
    do {
      return .success(try JSONDecoder().decode(ProbedHostCapabilities.self, from: data))
    } catch {
      return .failure("vmworker probe emitted unreadable JSON: \(error)")
    }
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
      failureReason: reason)
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
