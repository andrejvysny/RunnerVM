import Foundation
import RunnerCore

/// How `runnerd` is deployed on this host, and the checks that only make sense once that is known:
/// `service_mode`, `filevault`, `reboot_persistence`.
///
/// Several older checks were written for one deployment and misreport the other — `login_keychain`
/// most of all, which fails on a headless LaunchDaemon host that boots VMs perfectly well
/// (measured 2026-08-28, macOS 26.5.2/M4). Detecting the mode first lets each check say "not
/// applicable here" instead of inventing a problem.
enum ServiceMode: String, Sendable {
  case daemon
  case agent
  case foreground
}

/// The detected deployment plus whether launchd has actually loaded its job.
struct ServiceModeFacts: Sendable {
  var mode: ServiceMode
  var loaded: Bool
  /// The plist backing `mode`, or `nil` in `foreground`.
  var plistPath: String?
}

extension DoctorChecks {
  static let daemonPlistPath = "/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist"
  static let agentPlistPath = "/Library/LaunchAgents/com.runnervm.runnerd.agent.plist"
  static let launchdLabel = "com.runnervm.runnerd"

  /// An installed plist is the deployment intent; `launchctl print` is whether it took. The
  /// LaunchDaemon wins when both are installed — it is the one that survives a reboot, so it is
  /// the one whose absence matters.
  static func detectServiceMode(
    runProcess run: (String, [String]) -> ProcessResult = runProcess,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> ServiceModeFacts {
    if fileExists(daemonPlistPath) {
      let loaded = run("/bin/launchctl", ["print", "system/\(launchdLabel)"]).exitCode == 0
      return ServiceModeFacts(mode: .daemon, loaded: loaded, plistPath: daemonPlistPath)
    }
    if fileExists(agentPlistPath) {
      let loaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(launchdLabel)"]).exitCode == 0
      return ServiceModeFacts(mode: .agent, loaded: loaded, plistPath: agentPlistPath)
    }
    return ServiceModeFacts(mode: .foreground, loaded: false, plistPath: nil)
  }

  static func serviceMode(_ facts: ServiceModeFacts) -> DoctorCheck {
    let id = "service_mode"
    let title = "Service mode"
    switch facts.mode {
    case .foreground:
      return DoctorCheck(
        id: id, title: title, status: .ok,
        detail: "foreground (no launchd job installed); install one with "
          + "scripts/install.sh --launchd daemon"
      )
    case .daemon, .agent:
      let kind = facts.mode == .daemon ? "launchdaemon" : "launchagent"
      guard facts.loaded else {
        return DoctorCheck(
          id: id, title: title, status: .warn,
          detail: "\(kind) installed at \(facts.plistPath ?? "") but not loaded; "
            + bootstrapCommand(facts)
        )
      }
      return DoctorCheck(id: id, title: title, status: .ok, detail: "\(kind) (loaded)")
    }
  }

  /// FileVault is reported, never acted on: the trade-off (an encrypted boot volume versus a Mac
  /// that comes back on its own after a power cut) is the operator's to make, and RunnerVM works
  /// either way once the host is up.
  static func fileVault(
    runProcess run: (String, [String]) -> ProcessResult = runProcess
  ) -> DoctorCheck {
    let id = "filevault"
    let title = "FileVault"
    let result = run("/usr/bin/fdesetup", ["status"])
    let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.exitCode == 0, !text.isEmpty else {
      return DoctorCheck(
        id: id, title: title, status: .skip,
        detail: "could not read FileVault status (fdesetup exit \(result.exitCode))"
      )
    }
    if text.contains("FileVault is Off") {
      return DoctorCheck(id: id, title: title, status: .ok, detail: "FileVault is off")
    }
    guard text.contains("FileVault is On") else {
      return DoctorCheck(
        id: id, title: title, status: .skip,
        detail: "could not interpret fdesetup output: \(text)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .warn,
      detail: "FileVault is on; unattended cold boot may require pre-boot authentication before "
        + "runnerd can start; RunnerVM itself is unaffected"
    )
  }

  /// Does the daemon come back by itself after a reboot? Only a loaded LaunchDaemon answers yes:
  /// a LaunchAgent needs its account logged in first, which is a second thing to go wrong.
  static func rebootPersistence(_ facts: ServiceModeFacts) -> DoctorCheck {
    let id = "reboot_persistence"
    let title = "Reboot persistence"
    switch facts.mode {
    case .foreground:
      return DoctorCheck(
        id: id, title: title, status: .skip,
        detail: "no launchd job installed; runnerd will not survive a reboot"
      )
    case .agent:
      guard facts.loaded else {
        return DoctorCheck(
          id: id, title: title, status: .warn,
          detail: "launchagent installed but not loaded; \(bootstrapCommand(facts))"
        )
      }
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "launchagent loaded; it only restarts once its account has a login session "
          + "(autologin), so reboot recovery depends on that. The LaunchDaemon variant does not — "
          + "see packaging/launchd/README.md"
      )
    case .daemon:
      guard facts.loaded else {
        return DoctorCheck(
          id: id, title: title, status: .warn,
          detail: "launchdaemon installed but not loaded; \(bootstrapCommand(facts))"
        )
      }
      return DoctorCheck(
        id: id, title: title, status: .ok,
        detail: "launchdaemon loaded in system; runnerd starts at boot with no login session"
      )
    }
  }

  private static func bootstrapCommand(_ facts: ServiceModeFacts) -> String {
    guard let plistPath = facts.plistPath else { return "" }
    return facts.mode == .daemon
      ? "run: sudo launchctl bootstrap system \(plistPath)"
      : "run: launchctl bootstrap gui/\(getuid()) \(plistPath)"
  }
}
