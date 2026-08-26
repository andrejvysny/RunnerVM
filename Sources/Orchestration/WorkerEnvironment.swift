import Foundation

/// The environment `runnerd` hands to a freshly spawned `vmworker` process.
///
/// `runnerd` and `vmworker` sit on opposite sides of a trust boundary: `vmworker` drives
/// Virtualization.framework directly and its log output, crash reports and any guest-facing
/// tooling it shells out to are reachable in ways runnerd's own process is not. Credentials such
/// as `RUNNERVM_GITHUB_TOKEN` or a registry token live in runnerd's environment for its own
/// GitHub/registry clients and must never cross into the worker's -- inheriting
/// `ProcessInfo.processInfo.environment` wholesale would hand every such secret to a process that
/// has no need for it. `WorkerEnvironment.build` allowlists only the handful of variables
/// Foundation/Security/Virtualization.framework actually rely on to resolve `HOME`, temp files,
/// executable lookup and locale-dependent formatting.
public enum WorkerEnvironment {
  /// Exact variable names forwarded to `vmworker`. Deliberately exact, not prefix-matched: an
  /// unlisted variable never crosses the boundary, even one that happens to share a prefix with
  /// an entry here.
  public static let allowedVariables: [String] = [
    "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
  ]

  /// Used only when `parent` has no `PATH` at all, so the worker can still resolve helper tools.
  private static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  /// Keeps only `allowedVariables` present in `parent`. A pure function: callers pass
  /// `ProcessInfo.processInfo.environment` in explicitly rather than this reading it itself, so
  /// the allowlisting logic is testable without touching real process state.
  public static func build(from parent: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for key in allowedVariables {
      if let value = parent[key] {
        result[key] = value
      }
    }
    if result["PATH"] == nil {
      result["PATH"] = fallbackPath
    }
    return result
  }
}
