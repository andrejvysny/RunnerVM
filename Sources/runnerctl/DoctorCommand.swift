import ArgumentParser
import DaemonAPI
import Foundation
import RunnerCore

/// `runnerctl doctor` (spec §104, §23). Every check here works without a running daemon — that is
/// the whole point of a preflight tool — so this file never talks to `Sources/Orchestration` and
/// never links `Virtualization` directly; VM/host capability facts come from shelling out to
/// `vmworker probe`, the one process the spec allows to hold that entitlement (spec §7.2).
///
/// Individual checks live in `DoctorChecks.swift` (host platform, filesystem, sleep, launchd,
/// daemon), `DoctorVMWorkerChecks.swift` (vmworker binary/entitlement/probe) and
/// `DoctorConfigChecks.swift` (configuration, disk headroom, GitHub credential presence) — split
/// by concern to keep each file under the project's line-count convention.
struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check this host's readiness to install and run RunnerVM.",
    discussion: """
    Every check runs locally; no daemon is required. When runnerd.sock is reachable, doctor also
    folds in a summary of system.status. Exits 1 if any check fails.
    """
  )

  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "RunnerVM state root (default: development layout under $HOME).")
  var stateDir: String?

  @Option(name: .long, help: "Directory holding runnerd.sock and worker sockets.")
  var socketDir: String?

  @Option(name: .long, help: "Configuration file to validate against this host.")
  var config: String?

  func run() async throws {
    let paths = resolvedPaths()
    let socketURL = options.socket.map { URL(fileURLWithPath: $0) } ?? paths.daemonSocket
    let report = await DoctorChecks.runAll(paths: paths, configPath: config, daemonSocket: socketURL)
    switch options.output {
    case .json: try JSONOut.print(report)
    case .human: print(DoctorRender.render(report))
    }
    if report.hasFailures { throw ExitCode(1) }
  }

  /// Mirrors `RunnerD.resolvedPaths()`: `--state-dir` names the layout root (spec §22), not
  /// `RunnerPaths.stateDir`, which is one directory beneath it.
  private func resolvedPaths() -> RunnerPaths {
    let development = RunnerPaths.development(
      uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser
    )
    return RunnerPaths(
      rootDir: stateDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? development.rootDir,
      runtimeDir: socketDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? development.runtimeDir
    )
  }
}

// MARK: - Result model

struct DoctorCheck: Codable, Hashable {
  enum Status: String, Codable { case ok, warn, fail }

  var id: String
  var title: String
  var status: Status
  var detail: String
}

struct DoctorReport: Codable, Hashable {
  var checks: [DoctorCheck]
  var hasFailures: Bool {
    checks.contains { $0.status == .fail }
  }
}

// MARK: - Human rendering

enum DoctorRender {
  static func render(_ report: DoctorReport) -> String {
    let rows = report.checks.map { [symbol($0.status), $0.title, $0.detail] }
    let table = Table.render(headers: ["", "CHECK", "DETAIL"], rows: rows)
    let counts = Dictionary(grouping: report.checks, by: \.status).mapValues(\.count)
    let summary = "\(counts[.ok] ?? 0) ok, \(counts[.warn] ?? 0) warn, \(counts[.fail] ?? 0) fail"
    return table + "\n\n" + summary
  }

  private static func symbol(_ status: DoctorCheck.Status) -> String {
    switch status {
    case .ok: "ok"
    case .warn: "WARN"
    case .fail: "FAIL"
    }
  }
}
