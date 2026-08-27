import Foundation
import RunnerCore

/// In-daemon image builder readiness (Phase 6): `hdiutil` (the seed-image tool), the guest agent
/// binary the seed installs, and the shipped recipe root. Kept separate from `DoctorChecks.swift`
/// for the same reason as `DoctorVMWorkerChecks.swift`/`DoctorConfigChecks.swift` -- one concern
/// per file, under the project's line-count budget.
extension DoctorChecks {
  private static let hdiutilPath = "/usr/bin/hdiutil"

  /// `BuildSeed.write` shells out to exactly this `hdiutil makehybrid` invocation over the seed
  /// staging directory; the smoke test here runs the same command over an empty temp directory so
  /// doctor catches a broken/missing `hdiutil` before the first real build pays for the same
  /// discovery forty minutes in. The host is always macOS (every other check already assumes it),
  /// so there is no platform branch -- only present-and-working vs. not.
  static func buildTools() -> DoctorCheck {
    guard FileManager.default.isExecutableFile(atPath: hdiutilPath) else {
      return DoctorCheck(
        id: "build_tools", title: "Build tools (hdiutil)", status: .fail,
        detail: "\(hdiutilPath) not found; image builds cannot render a boot seed")
    }
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("runnervm-doctor-hdiutil-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    do {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    } catch {
      return DoctorCheck(
        id: "build_tools", title: "Build tools (hdiutil)", status: .fail,
        detail: "could not create a scratch directory to test hdiutil: \(error)")
    }
    let iso = staging.appendingPathComponent("smoke-test.iso")
    let result = runProcess(hdiutilPath, [
      "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
      "-o", iso.path, staging.path,
    ])
    guard result.exitCode == 0 else {
      return DoctorCheck(
        id: "build_tools", title: "Build tools (hdiutil)", status: .fail,
        detail: "hdiutil makehybrid smoke test failed (exit \(result.exitCode))"
      )
    }
    return DoctorCheck(
      id: "build_tools", title: "Build tools (hdiutil)", status: .ok,
      detail: "\(hdiutilPath) present; makehybrid smoke test succeeded"
    )
  }

  /// Mirrors `BuildSeed.resolveAgent`'s config/environment/rootDir precedence (in that order).
  /// Its fourth candidate is relative to runnerd's own executable, which `runnerctl` has no way to
  /// know from here -- and `scripts/install.sh` always populates the rootDir path anyway, so this
  /// omission never hides a real production layout.
  static func guestAgentCandidates(
    paths: RunnerPaths, config: RunnerConfiguration?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    var result: [String] = []
    if let configured = config?.build.guestAgentPath, !configured.isEmpty {
      result.append(configured)
    }
    if let override = environment["RUNNERVM_GUEST_AGENT"], !override.isEmpty {
      result.append(override)
    }
    result.append(
      paths.rootDir.appending(path: "guest-agent/linux-arm64/runnervm-guest-agent").path)
    return result
  }

  static func buildGuestAgent(paths: RunnerPaths, config: RunnerConfiguration?) -> DoctorCheck {
    let candidates = guestAgentCandidates(paths: paths, config: config)
    guard let found = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
    else {
      return DoctorCheck(
        id: "build_guest_agent", title: "Build guest agent", status: .fail,
        detail: "not found; tried: \(candidates.joined(separator: ", ")); build and install it "
          + "with `make -C GuestAgent build-linux` + scripts/install.sh, or set "
          + "RUNNERVM_GUEST_AGENT"
      )
    }
    return DoctorCheck(
      id: "build_guest_agent", title: "Build guest agent", status: .ok, detail: "found at \(found)"
    )
  }

  /// `scripts/install.sh` copies the shipped `images/recipes/` here; absence only means an
  /// operator has not installed them (or always builds from a custom recipe path directly), which
  /// is a perfectly valid setup -- hence `warn`, not `fail`.
  static func buildRecipes(paths: RunnerPaths) -> DoctorCheck {
    let dir = paths.rootDir.appending(path: "share/recipes", directoryHint: .isDirectory)
    let manager = FileManager.default
    guard manager.fileExists(atPath: dir.path) else {
      return DoctorCheck(
        id: "build_recipes", title: "Build recipes", status: .warn,
        detail: "\(dir.path) does not exist yet; install the shipped recipes with "
          + "scripts/install.sh, or point `runnerctl image build` at any Runnerfile directly"
      )
    }
    guard manager.isReadableFile(atPath: dir.path) else {
      return DoctorCheck(
        id: "build_recipes", title: "Build recipes", status: .fail,
        detail: "\(dir.path) exists but is not readable"
      )
    }
    return DoctorCheck(
      id: "build_recipes", title: "Build recipes", status: .ok,
      detail: "\(dir.path) exists and is readable"
    )
  }
}
