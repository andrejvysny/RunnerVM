import ArgumentParser
import DaemonAPI
import Foundation

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show daemon, host, capacity and profile health.")

  @OptionGroup var options: GlobalOptions

  func run() async throws {
    let status = try await options.withDaemon { try await $0.status() }
    switch options.output {
    case .json: try JSONOut.print(status)
    case .human: print(Status.render(status))
    }
  }

  /// Layout follows spec §103 so operators see the same shape the design document promises.
  static func render(_ status: SystemStatus) -> String {
    var blocks = ["RunnerVM daemon: \(status.daemon.state.rawValue)"]
    blocks.append(section("Host", hostFields(status)))
    blocks.append(section("Capacity", capacityFields(status.capacity)))
    blocks.append(section("GitHub", githubFields(status.github)))
    blocks.append(section("Images", imageFields(status.images)))
    blocks.append("Profiles\n" + profileLines(status.profiles))
    blocks.append(section("Reconciliation", reconciliationFields(status.reconciliation)))
    return blocks.joined(separator: "\n\n")
  }

  private static func imageFields(_ images: ImageSummary) -> [(String, String)] {
    var fields = [
      ("Cached", "\(images.cached) ready (\(images.runnerStale) stale, "
        + "\(images.runnerTooOld) too old)"),
      ("Disk usage", Format.bytes(images.diskUsageBytes)),
    ]
    if images.pulling > 0 { fields.append(("Pulling", "\(images.pulling)")) }
    return fields
  }

  private static func section(_ title: String, _ fields: [(String, String)]) -> String {
    "\(title)\n" + Table.fields(fields)
  }

  private static func hostFields(_ status: SystemStatus) -> [(String, String)] {
    var fields: [(String, String)] = [
      ("macOS", status.host.osVersion),
      ("architecture", status.host.architecture),
      ("CPUs", "\(status.host.logicalCPUCount)"),
      ("Memory", Format.bytes(status.host.physicalMemoryBytes)),
      ("Free disk", Format.bytes(status.host.freeDiskBytes)),
      ("Disk pressure", Status.diskPressureField(status.diskPressure)),
      ("Daemon", "pid \(status.daemon.pid), up \(Format.duration(seconds: status.daemon.uptimeSeconds))"),
      ("Mode", modeField(status.daemon)),
    ]
    if !status.host.probeSucceeded {
      fields.append(("Probe", "unavailable (\(Format.optional(status.host.probeError)))"))
    }
    return fields
  }

  /// Spec §109: a drain that is still waiting on jobs is not the same operational state as one
  /// that has finished, so the count belongs next to the mode.
  private static func modeField(_ daemon: DaemonHealth) -> String {
    guard daemon.mode != "normal" else { return daemon.mode }
    let jobs = daemon.activeSessions == 1 ? "1 active job" : "\(daemon.activeSessions) active jobs"
    return "\(daemon.mode) (\(jobs))"
  }

  private static func diskPressureField(_ pressure: DiskPressureSummary) -> String {
    "\(pressure.state) (free \(Format.bytes(pressure.freeBytes)), floor \(Format.bytes(pressure.floorBytes)))"
  }

  private static func capacityFields(_ capacity: CapacitySummary) -> [(String, String)] {
    [
      ("Running VMs", "\(capacity.runningVMs) / \(capacity.maxVMs.map(String.init) ?? "auto")"),
      ("Reserved CPU", "\(capacity.reservedCPUCount)"),
      ("Reserved RAM", Format.bytes(capacity.reservedMemoryBytes)),
      ("Reserved disk", Format.bytes(capacity.reservedDiskBytes)),
    ]
  }

  private static func githubFields(_ github: GitHubSummary) -> [(String, String)] {
    [
      ("Auth", github.authLogin.map { "\(github.authState) (\($0))" } ?? github.authState),
      ("Scopes", "\(github.scopesHealthy) healthy / \(github.scopeCount) enabled"),
      ("Scale sets", "\(github.scaleSetsHealthy) healthy"),
    ]
  }

  private static func reconciliationFields(
    _ reconciliation: ReconciliationSummary
  ) -> [(String, String)] {
    [
      ("Last run", reconciliation.secondsSinceLastRun.map { "\(Format.duration(seconds: $0)) ago" }
        ?? "never"),
      ("Runs", "\(reconciliation.runCount)"),
      ("Errors", "\(reconciliation.errorCount)"),
      ("Instances", "\(reconciliation.instanceCount)"),
      ("Workers", "\(reconciliation.workerCount) connected"),
      ("Orphans", "\(reconciliation.orphanCount)"),
    ]
  }

  private static func profileLines(_ profiles: [ProfileRuntimeSummary]) -> String {
    guard !profiles.isEmpty else { return "  (none configured)" }
    let width = profiles.map(\.name.count).max() ?? 0
    return profiles
      .map {
        let name = $0.name.padding(toLength: width, withPad: " ", startingAt: 0)
        let suffix = $0.enabled ? "" : "  (disabled)"
        return "  \(name)   demand \($0.demand) / \($0.busy) busy / \($0.idle) idle / "
          + "\($0.starting) starting\(suffix)"
      }
      .joined(separator: "\n")
  }
}

struct Version: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version", abstract: "Show the daemon build and protocol versions.")

  @OptionGroup var options: GlobalOptions

  func run() async throws {
    let version = try await options.withDaemon { try await $0.version() }
    switch options.output {
    case .json:
      try JSONOut.print(version)
    case .human:
      print(
        Table.fields(
          [
            ("runnerd", version.version),
            ("protocol", "\(version.protocolName) v\(version.protocolVersion)"),
            ("schema", "v\(version.schemaVersion)"),
          ], indent: ""))
    }
  }
}
