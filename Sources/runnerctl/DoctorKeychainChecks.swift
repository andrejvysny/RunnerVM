import Foundation
import RunnerCore

extension DoctorChecks {
  /// The folklore — repeated by Tart/Cirrus and by this repo's own packaging until now — is that
  /// Virtualization.framework on macOS 15+ needs an unlocked login keychain in the creating
  /// process's session, which a LaunchDaemon has none of.
  ///
  /// Measured 2026-08-28 on a headless Mac mini (macOS 26.5.2, M4, nobody logged in): every VM
  /// booted — two image builds, ten GitHub jobs, eleven live E2E scenarios — while this check
  /// reported the login keychain locked. So it is a *false negative* under a LaunchDaemon, and
  /// reporting it as a hard failure sent operators chasing a keychain that was never the problem.
  ///
  /// It is therefore skipped outright in daemon mode, and downgraded to a warning everywhere else:
  /// still worth surfacing on a workstation whose LaunchAgent really does run inside a GUI
  /// session, never a reason for `doctor` to exit non-zero.
  static func loginKeychainUnlocked(mode: ServiceMode) -> DoctorCheck {
    let id = "login_keychain"
    let title = "Login keychain"
    guard mode != .daemon else {
      return DoctorCheck(
        id: id, title: title, status: .skip,
        detail: "headless LaunchDaemon does not depend on a login keychain (measured 2026-08-28: "
          + "VMs boot with it locked)"
      )
    }
    let user = NSUserName()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let keychain = home.appending(path: "Library/Keychains/login.keychain-db")
    let path = keychain.path(percentEncoded: false)
    let hint = "informational: if VM start fails with SecKeyCreateRandomKey_ios, run doctor as the "
      + "account runnerd runs as and see docs/qualification.md"
    guard FileManager.default.fileExists(atPath: path) else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "no login keychain for \(user) at \(path); \(hint)"
      )
    }
    let result = runProcess("/usr/bin/security", ["show-keychain-info", path])
    guard result.exitCode == 0 else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "login keychain for \(user) is locked (security exit \(result.exitCode)); \(hint)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "login keychain for \(user) is unlocked"
    )
  }
}
