import Foundation

/// Pure lookup behind `runnerctl doctor`'s `gitlab_fleeting_plugin` check. gitlab-runner resolves
/// `plugin = "runnervm"` by finding an executable named `fleeting-plugin-runnervm` on `PATH`, so
/// that is exactly what doctor looks for; the filesystem probe is injected so tests need no files.
public enum DoctorFleetingPlugin {
  public static let binaryName = "fleeting-plugin-runnervm"

  /// Directories the pkg and `scripts/install.sh` put binaries in, searched after `PATH` because a
  /// LaunchDaemon's `PATH` is minimal and gitlab-runner can still be given an absolute path.
  public static let extraDirectories = ["/usr/local/bin", "/opt/homebrew/bin"]

  public static let fix =
    "build it with `make -C GuestAgent build-plugin` and install "
    + "GuestAgent/dist/fleeting-plugin-runnervm-darwin-arm64 as `\(binaryName)` on gitlab-runner's "
    + "PATH (see docs/gitlab.md)"

  public static func candidates(path: String?) -> [String] {
    let dirs = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    var seen = Set<String>()
    return (dirs + extraDirectories)
      .filter { seen.insert($0).inserted }
      .map { "\($0)/\(binaryName)" }
  }

  public static func locate(path: String?, isExecutable: (String) -> Bool) -> String? {
    candidates(path: path).first(where: isExecutable)
  }

  /// `nil` when the configuration has no GitLab profile, which means the check does not apply.
  public static func check(
    hasGitLabProfile: Bool, path: String?, isExecutable: (String) -> Bool
  ) -> DoctorCheck? {
    guard hasGitLabProfile else { return nil }
    let id = "gitlab_fleeting_plugin"
    let title = "GitLab fleeting plugin"
    if let found = locate(path: path, isExecutable: isExecutable) {
      return DoctorCheck(id: id, title: title, status: .ok, detail: "found at \(found)")
    }
    return DoctorCheck(
      id: id, title: title, status: .warn,
      detail: "\(binaryName) not found on PATH or in \(extraDirectories.joined(separator: ", ")); "
        + "gitlab-runner cannot start `plugin = \"runnervm\"` without it. Fix: \(fix)")
  }
}
