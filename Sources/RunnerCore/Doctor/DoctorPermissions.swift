import Foundation

/// Pure permission/ownership arithmetic behind `runnerctl doctor`'s filesystem checks (spec WP9:
/// `service_user_ownership`, `runtime_dir_perms`). Takes already-`stat`-ed facts rather than
/// touching disk itself -- the actual `stat(2)`/`getpwnam(3)` calls live in `runnerctl`, which is
/// the only thing that needs a live filesystem or directory service to test against.
public enum DoctorPermissions {
  /// `st_mode`'s read/write/execute bits, with the file-type bits masked off.
  public static func permissionBits(_ mode: UInt16) -> UInt16 { mode & 0o7777 }

  /// True when `mode` sets any bit `ceiling` does not -- i.e. `mode` is looser than "at most
  /// `ceiling`". "0750 or stricter" means every bit `mode` sets must already be one `ceiling` sets.
  public static func exceeds(mode: UInt16, ceiling: UInt16) -> Bool {
    permissionBits(mode) & ~permissionBits(ceiling) != 0
  }

  /// Any "other" (world) read/write/execute bit set.
  public static func isWorldAccessible(mode: UInt16) -> Bool {
    permissionBits(mode) & 0o007 != 0
  }

  /// Renders a mode the way a doctor detail string does, e.g. `0750`. Zero-padded to 3 digits
  /// before the leading `0` so an all-zero mode still prints `0000`, not `00`.
  public static func octal(_ mode: UInt16) -> String {
    String(format: "0%03o", permissionBits(mode))
  }
}

/// Which account `<state-dir>` and its contents should be owned by, given the layout in use
/// (`RunnerPaths.production()` vs. `RunnerPaths.development(uid:home:)`). Pure string/path logic;
/// resolving a name to a uid is the caller's job (`getpwnam`), since that needs the directory
/// service.
public enum DoctorServiceAccount {
  /// `RunnerPaths.production().rootDir.path` -- duplicated as a literal rather than depending on
  /// `RunnerPaths` here, since the whole point is a comparison the caller does against a real
  /// (possibly `--state-dir`-overridden) path.
  public static let productionRootDir = "/Library/Application Support/RunnerVM"
  /// `scripts/install.sh`'s `--user` default (`docs/install.md`).
  public static let defaultServiceUser = "_runnervm"

  /// `nil` means "whichever account is running this check" -- a development layout (state dir
  /// under a user's home, per `RunnerPaths.development`) has no single expected owner to compare
  /// against. An explicit `--service-user` override always wins over the layout-based default.
  public static func expectedAccountName(rootDirPath: String, override: String?) -> String? {
    if let override, !override.isEmpty { return override }
    return rootDirPath == productionRootDir ? defaultServiceUser : nil
  }
}
