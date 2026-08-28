import Foundation
import RunnerCore

/// Filesystem ownership and permission checks for the account `runnerd` actually runs as (spec
/// WP9): the state directory, `config.yaml`, `state/`/`logs/`, and the runtime socket directory
/// plus its sockets -- matching the layout and modes `scripts/install.sh` creates
/// (`docs/install.md`: state dir 0750, runtime dir 0700, `logs/` 0750, `config.yaml` 0640, all
/// owned by the service user/group). Entirely read-only: nothing here ever `chmod`s or `chown`s.
extension DoctorChecks {
  // MARK: - Account/stat primitives

  /// Resolves an account name to a uid via the directory service; `nil` when no such account
  /// exists yet (e.g. `scripts/install.sh` has not created `_runnervm`).
  static func uid(forAccount name: String) -> uid_t? {
    getpwnam(name)?.pointee.pw_uid
  }

  struct PathStat {
    var uid: uid_t
    var mode: UInt16
  }

  /// `lstat`, not `stat`: a symlinked state/runtime directory (or a swapped-in one) should be
  /// reported on its own mode/owner, not silently followed, matching `SecureFile`'s posture on
  /// credential files.
  static func statPath(_ path: String) -> PathStat? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return PathStat(uid: info.st_uid, mode: UInt16(info.st_mode & 0o7777))
  }

  /// The uid every ownership check compares against, plus a human label for detail strings. A
  /// dev layout with no `--service-user` override falls back to whichever uid is running doctor
  /// right now -- there is no single "correct" owner to check a developer's own
  /// `~/Library/Application Support/RunnerVM` against. An account name that does not resolve
  /// (not created yet) compares against a uid nothing on the host can hold, so a real mismatch is
  /// still reported instead of silently passing.
  static func expectedOwner(
    rootDirPath: String, overrideServiceUser: String?
  ) -> (uid: uid_t, label: String) {
    guard let name = DoctorServiceAccount.expectedAccountName(
      rootDirPath: rootDirPath, override: overrideServiceUser)
    else {
      return (getuid(), "uid \(getuid()) (this account)")
    }
    guard let resolved = uid(forAccount: name) else {
      return (uid_t.max, "\(name) (account does not exist on this host)")
    }
    return (resolved, "\(name) (uid \(resolved))")
  }

  private static func checkOwnerAndMode(
    _ path: String, ceiling: UInt16, expected: (uid: uid_t, label: String), issues: inout [String],
    optional: Bool = false
  ) {
    guard let info = statPath(path) else {
      if !optional { issues.append("could not stat \(path)") }
      return
    }
    if info.uid != expected.uid {
      issues.append("\(path) is owned by uid \(info.uid), expected \(expected.label)")
    }
    if DoctorPermissions.exceeds(mode: info.mode, ceiling: ceiling) {
      issues.append(
        "\(path) is mode \(DoctorPermissions.octal(info.mode)); must be "
          + "\(DoctorPermissions.octal(ceiling)) or stricter")
    }
  }

  // MARK: - service_user_ownership

  static func serviceUserOwnership(paths: RunnerPaths, overrideServiceUser: String?) -> DoctorCheck {
    let id = "service_user_ownership"
    let title = "Service account ownership"
    guard FileManager.default.fileExists(atPath: paths.rootDir.path) else {
      return DoctorCheck(
        id: id, title: title, status: .skip,
        detail: "\(paths.rootDir.path) does not exist yet; skipped"
      )
    }
    let expected = expectedOwner(
      rootDirPath: paths.rootDir.path, overrideServiceUser: overrideServiceUser)
    var issues: [String] = []
    checkOwnerAndMode(paths.rootDir.path, ceiling: 0o750, expected: expected, issues: &issues)
    checkOwnerAndMode(
      paths.rootDir.appending(path: "config.yaml").path, ceiling: 0o640, expected: expected,
      issues: &issues, optional: true
    )
    checkOwnerAndMode(
      paths.stateDir.path, ceiling: 0o750, expected: expected, issues: &issues, optional: true)
    checkOwnerAndMode(
      paths.logsDir.path, ceiling: 0o750, expected: expected, issues: &issues, optional: true)
    guard issues.isEmpty else {
      return DoctorCheck(id: id, title: title, status: .fail, detail: issues.joined(separator: "; "))
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(paths.rootDir.path) and its top-level contents are owned by \(expected.label), "
        + "0750/0640-or-stricter, no world access"
    )
  }

  // MARK: - runtime_dir_perms

  static func runtimeDirPerms(paths: RunnerPaths, overrideServiceUser: String?) -> DoctorCheck {
    let id = "runtime_dir_perms"
    let title = "Runtime directory permissions"
    let dir = paths.runtimeDir
    guard FileManager.default.fileExists(atPath: dir.path) else {
      return DoctorCheck(
        id: id, title: title, status: .skip, detail: "\(dir.path) does not exist yet; skipped")
    }
    let expected = expectedOwner(
      rootDirPath: paths.rootDir.path, overrideServiceUser: overrideServiceUser)
    var issues: [String] = []
    checkOwnerAndMode(dir.path, ceiling: 0o700, expected: expected, issues: &issues)
    let sockets =
      (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
      .filter { $0.hasSuffix(".sock") } ?? []
    for name in sockets {
      guard let info = statPath(dir.appending(path: name).path) else { continue }
      if DoctorPermissions.exceeds(mode: info.mode, ceiling: 0o600) {
        issues.append(
          "\(name) is mode \(DoctorPermissions.octal(info.mode)); sockets must be 0600 or "
            + "stricter")
      }
    }
    guard issues.isEmpty else {
      return DoctorCheck(id: id, title: title, status: .fail, detail: issues.joined(separator: "; "))
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(dir.path) is 0700, owned by \(expected.label); \(sockets.count) socket(s) are "
        + "0600 or stricter"
    )
  }
}
