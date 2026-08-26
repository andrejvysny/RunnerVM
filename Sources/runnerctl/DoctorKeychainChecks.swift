import Foundation

extension DoctorChecks {
  /// Virtualization.framework on macOS 15+ needs an unlocked login keychain in the process's
  /// session to start a VM (`SecKeyCreateRandomKey_ios failed` otherwise). A LaunchDaemon session
  /// has none unless one was provisioned, which is the headless deployment's main failure mode —
  /// so a locked or missing keychain is a hard failure here, not a warning.
  static func loginKeychainUnlocked() -> DoctorCheck {
    let user = NSUserName()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let keychain = home.appending(path: "Library/Keychains/login.keychain-db")
    let path = keychain.path(percentEncoded: false)
    let hint = "VM start needs an unlocked login keychain for the account runnerd runs as; "
      + "run doctor as that account and see docs/qualification.md"
    guard FileManager.default.fileExists(atPath: path) else {
      return DoctorCheck(
        id: "login_keychain", title: "Login keychain", status: .fail,
        detail: "no login keychain for \(user) at \(path); \(hint)"
      )
    }
    let result = runProcess("/usr/bin/security", ["show-keychain-info", path])
    guard result.exitCode == 0 else {
      return DoctorCheck(
        id: "login_keychain", title: "Login keychain", status: .fail,
        detail: "login keychain for \(user) is locked (security exit \(result.exitCode)); \(hint)"
      )
    }
    return DoctorCheck(
      id: "login_keychain", title: "Login keychain", status: .ok,
      detail: "login keychain for \(user) is unlocked"
    )
  }
}
