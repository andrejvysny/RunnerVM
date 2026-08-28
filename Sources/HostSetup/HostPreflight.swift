import CryptoKit
import Foundation
import RunnerCore

/// Everything `runnerctl setup` needs to know about the machine before it proposes anything.
///
/// Named `SetupHostFacts` rather than `HostFacts` on purpose: `RunnerCore.HostFacts` already means
/// "the Virtualization.framework limits configuration validation compares against", which is a
/// different question with a different shape. This one is about the physical host.
public struct SetupHostFacts: Sendable, Hashable, Codable {
  /// `hw.model`, e.g. `Mac16,10`.
  public var model: String
  public var cpuCount: Int
  public var memoryBytes: UInt64
  /// Free space on the volume the state directory will live on.
  public var freeDiskBytes: UInt64
  /// `sw_vers -productVersion`, e.g. `26.5.2`.
  public var macOSVersion: String
  public var isAppleSilicon: Bool
  /// First 6 lowercase hex characters of `sha256(IOPlatformUUID)` — the stable per-host token the
  /// default profile names are built from (`docs/design/distribution.md`, "Default profile
  /// naming"). Empty only when `ioreg` produced nothing parseable.
  public var hostID6: String
  public var fileVault: FileVaultStatus
  public var existingInstall: ExistingInstall

  public init(
    model: String, cpuCount: Int, memoryBytes: UInt64, freeDiskBytes: UInt64,
    macOSVersion: String, isAppleSilicon: Bool, hostID6: String,
    fileVault: FileVaultStatus = .unknown, existingInstall: ExistingInstall = ExistingInstall()
  ) {
    self.model = model
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.freeDiskBytes = freeDiskBytes
    self.macOSVersion = macOSVersion
    self.isAppleSilicon = isAppleSilicon
    self.hostID6 = hostID6
    self.fileVault = fileVault
    self.existingInstall = existingInstall
  }
}

/// What is already on the host. `setup` is re-runnable, so this drives wording ("reconfiguring an
/// existing install") rather than a refusal.
public struct ExistingInstall: Sendable, Hashable, Codable {
  public var stateDirectory: Bool
  public var configFile: Bool
  public var daemonPlist: Bool
  public var agentPlist: Bool

  public init(
    stateDirectory: Bool = false, configFile: Bool = false, daemonPlist: Bool = false,
    agentPlist: Bool = false
  ) {
    self.stateDirectory = stateDirectory
    self.configFile = configFile
    self.daemonPlist = daemonPlist
    self.agentPlist = agentPlist
  }

  public var isPresent: Bool { stateDirectory || configFile || daemonPlist || agentPlist }

  public var summary: String {
    guard isPresent else { return "none" }
    var parts: [String] = []
    if stateDirectory { parts.append("state directory") }
    if configFile { parts.append("config.yaml") }
    if daemonPlist { parts.append("launchdaemon") }
    if agentPlist { parts.append("launchagent") }
    return parts.joined(separator: ", ")
  }
}

/// Gathers `SetupHostFacts`. Every acquisition goes through `CommandRunner` (or a read-only
/// syscall); every piece of parsing is a static pure function so the fixture strings in
/// `HostSetupTests` are the whole test.
public struct HostPreflight: Sendable {
  public static let daemonPlistPath = "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist"
  public static let agentPlistPath = "/Library/LaunchAgents/com.runnervm.runnerd.agent.plist"

  private let runner: any CommandRunner
  private let fileExists: @Sendable (String) -> Bool
  private let freeDisk: @Sendable (String) -> UInt64

  public init(
    runner: any CommandRunner = DefaultCommandRunner(),
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    freeDisk: @escaping @Sendable (String) -> UInt64 = HostPreflight.freeDiskBytes(onVolumeAt:)
  ) {
    self.runner = runner
    self.fileExists = fileExists
    self.freeDisk = freeDisk
  }

  public func gather(stateDir: String, configPath: String) async -> SetupHostFacts {
    async let model = sysctl("hw.model")
    async let cpu = sysctl("hw.logicalcpu")
    async let memory = sysctl("hw.memsize")
    async let arm = sysctl("hw.optional.arm64")
    async let version = capture(["/usr/bin/sw_vers", "-productVersion"])
    async let ioreg = capture(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    async let fileVault = fileVaultStatus()

    return await SetupHostFacts(
      model: model,
      cpuCount: Int(cpu) ?? 0,
      memoryBytes: UInt64(memory) ?? 0,
      freeDiskBytes: freeDisk("/"),
      macOSVersion: version,
      isAppleSilicon: arm == "1",
      hostID6: Self.hostID6(ioregOutput: ioreg) ?? "",
      fileVault: fileVault,
      existingInstall: ExistingInstall(
        stateDirectory: fileExists(stateDir),
        configFile: fileExists(configPath),
        daemonPlist: fileExists(Self.daemonPlistPath),
        agentPlist: fileExists(Self.agentPlistPath)))
  }

  // MARK: - Acquisition

  private func sysctl(_ name: String) async -> String {
    await capture(["/usr/sbin/sysctl", "-n", name])
  }

  private func capture(_ argv: [String]) async -> String {
    guard let result = try? await runner.run(argv), result.isSuccess else { return "" }
    return result.trimmedStdout
  }

  private func fileVaultStatus() async -> FileVaultStatus {
    guard let result = try? await runner.run(["/usr/bin/fdesetup", "status"]) else {
      return .unknown
    }
    return FileVaultStatus.parse(output: result.stdout, exitCode: result.exitCode)
  }

  /// `statfs(2)` on the volume: read-only, no subprocess, and the same number `df` reports.
  public static func freeDiskBytes(onVolumeAt path: String) -> UInt64 {
    var stats = statfs()
    guard statfs(path, &stats) == 0 else { return 0 }
    return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
  }

  // MARK: - Parsing

  /// Pulls `IOPlatformUUID` out of `ioreg -rd1 -c IOPlatformExpertDevice`, whose relevant line is
  /// `    "IOPlatformUUID" = "0E4E0D1F-…"`.
  public static func parsePlatformUUID(ioregOutput: String) -> String? {
    for line in ioregOutput.split(separator: "\n") where line.contains("IOPlatformUUID") {
      let quoted = line.split(separator: "\"", omittingEmptySubsequences: true)
      // ["    ", "IOPlatformUUID", " = ", "<uuid>"] once the separators are dropped.
      guard let value = quoted.last.map(String.init), value != "IOPlatformUUID",
            !value.trimmingCharacters(in: .whitespaces).isEmpty
      else { continue }
      return value
    }
    return nil
  }

  /// `sha256(IOPlatformUUID)`, first 6 lowercase hex characters. Hashed rather than truncated so
  /// the host's real hardware UUID is not published as part of a runner name on GitHub.
  public static func hostID6(platformUUID: String) -> String {
    let digest = SHA256.hash(data: Data(platformUUID.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(6).lowercased()
  }

  public static func hostID6(ioregOutput: String) -> String? {
    parsePlatformUUID(ioregOutput: ioregOutput).map(hostID6(platformUUID:))
  }
}
