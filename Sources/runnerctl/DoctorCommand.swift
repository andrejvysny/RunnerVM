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
/// daemon), `DoctorVMWorkerChecks.swift` (vmworker binary/entitlement/probe),
/// `DoctorConfigChecks.swift` (configuration, disk headroom, GitHub credential presence) and
/// `DoctorServiceModeChecks.swift` (how runnerd is deployed, FileVault, reboot persistence) —
/// split by concern to keep each file under the project's line-count convention.
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

  @Option(
    name: .long,
    help: ArgumentHelp(
      "RunnerVM state root.",
      discussion: "Falls back to RUNNERVM_STATE_DIR, then the production layout when it exists, "
        + "then the development layout under $HOME."))
  var stateDir: String?

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Directory holding runnerd.sock and worker sockets.",
      discussion: "Falls back to RUNNERVM_RUNTIME_DIR, then the production runtime directory "
        + "when it exists."))
  var socketDir: String?

  @Option(name: .long, help: "Configuration file to validate against this host.")
  var config: String?

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Expected owner of the state/runtime directories.",
      discussion: "Default: _runnervm in a production layout, this account in a development "
        + "layout."))
  var serviceUser: String?

  @Flag(
    name: .long,
    help: ArgumentHelp(
      "Also re-hash every image blob's sha256 against its manifest (image_store_integrity).",
      discussion: "Slow for large images, off by default."))
  var deep = false

  func run() async throws {
    let paths = resolvedPaths()
    let socketURL = RunnerPaths.socketOverride(explicit: options.socket) ?? paths.daemonSocket
    let report = await DoctorChecks.runAll(
      paths: paths, configPath: config, daemonSocket: socketURL, serviceUser: serviceUser,
      mode: DoctorChecks.detectServiceMode(), deep: deep
    )
    switch options.output {
    case .json: try JSONOut.print(report)
    case .human: print(DoctorRender.render(report))
    }
    if report.hasFailures { throw ExitCode(1) }
  }

  /// Mirrors `RunnerD.resolvedPaths()` by calling the same resolver: `--state-dir` names the
  /// layout root (spec §22), not `RunnerPaths.stateDir`, which is one directory beneath it. With
  /// no flags and no `RUNNERVM_STATE_DIR`/`RUNNERVM_RUNTIME_DIR`, an existing production install
  /// is detected rather than assumed absent — doctor used to check the developer layout on a host
  /// running a LaunchDaemon and report a pile of false negatives.
  private func resolvedPaths() -> RunnerPaths {
    RunnerPaths.resolveRoots(stateDir: stateDir, socketDir: socketDir)
  }
}

// MARK: - Human rendering

/// `DoctorCheck`/`DoctorReport` live in `RunnerCore` (`Doctor/DoctorModel.swift`) so their status
/// semantics are covered by `Tests/RunnerCoreTests`; there is no `runnerctl` test target.
enum DoctorRender {
  static func render(_ report: DoctorReport) -> String {
    let rows = report.checks.map { [DoctorStatusSymbol.symbol(for: $0.status), $0.title, $0.detail] }
    let table = Table.render(headers: ["", "CHECK", "DETAIL"], rows: rows)
    let summary = "\(report.count(of: .ok)) ok, \(report.count(of: .warn)) warn, "
      + "\(report.count(of: .fail)) fail, \(report.count(of: .skip)) skipped"
    return table + "\n\n" + summary
  }
}
