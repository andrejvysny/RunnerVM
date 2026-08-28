import Foundation

/// Layout auto-discovery: how `runnerd`, `runnerctl` and `runnerctl doctor` all agree on which
/// install they are talking about (spec §22).
///
/// Before this existed each of the three resolved paths itself and every one of them fell straight
/// back to the *development* layout, so `runnerctl status` on a host with a production LaunchDaemon
/// installed silently probed `/tmp/runnervm-<uid>/runnerd.sock` and reported "daemon unreachable".
/// The precedence is identical for every component:
///
///     explicit flag  >  environment variable  >  production layout, if it exists on disk  >  dev
///
/// Every disk probe is injected (`fileExists`), as is the environment, so the precedence matrix is
/// testable without a production install — `RunnerCore` stays I/O-free.
extension RunnerPaths {
  /// Environment overrides `scripts/qualify-macos-image.sh` and friends already export.
  public enum Environment {
    public static let socket = "RUNNERVM_SOCKET"
    public static let stateDir = "RUNNERVM_STATE_DIR"
    public static let runtimeDir = "RUNNERVM_RUNTIME_DIR"
  }

  /// `development(uid:home:)` for the account running this process. Reads process identity only;
  /// nothing here touches the filesystem.
  public static func developmentForCurrentUser() -> RunnerPaths {
    development(uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser)
  }

  /// The default `fileExists` probe. Public only so it can be a default argument below.
  public static func defaultFileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  /// The socket a caller *demanded*, from the flag or the environment — `nil` when neither is set.
  ///
  /// Split out from `resolveSocket` because `doctor` already resolves a full layout from
  /// `--state-dir`/`--socket-dir` and only needs to know whether an override beats it; folding the
  /// production probe in there would let an existing production install override an explicit
  /// `--socket-dir`.
  public static func socketOverride(
    explicit: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let explicit, !explicit.isEmpty { return URL(fileURLWithPath: explicit) }
    if let fromEnvironment = environment[Environment.socket], !fromEnvironment.isEmpty {
      return URL(fileURLWithPath: fromEnvironment)
    }
    return nil
  }

  /// `--socket` > `RUNNERVM_SOCKET` > the production socket if it exists > the development socket.
  public static func resolveSocket(
    explicit: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    development: RunnerPaths = developmentForCurrentUser(),
    fileExists: (String) -> Bool = defaultFileExists
  ) -> URL {
    if let override = socketOverride(explicit: explicit, environment: environment) { return override }
    let productionSocket = production().daemonSocket
    if fileExists(productionSocket.path(percentEncoded: false)) { return productionSocket }
    return development.daemonSocket
  }

  /// Same precedence as `resolveSocket`, applied per component: `rootDir` probes the production
  /// state root, `runtimeDir` probes the production daemon socket. The two are independent so a
  /// half-installed host (state directory laid out, daemon never started) still resolves its state
  /// root correctly.
  public static func resolveRoots(
    stateDir: String?,
    socketDir: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    development: RunnerPaths = developmentForCurrentUser(),
    fileExists: (String) -> Bool = defaultFileExists
  ) -> RunnerPaths {
    let productionPaths = production()
    return RunnerPaths(
      rootDir: resolveDirectory(
        explicit: stateDir, environmentValue: environment[Environment.stateDir],
        production: productionPaths.rootDir, developmentValue: development.rootDir,
        productionExists: fileExists(productionPaths.rootDir.path(percentEncoded: false))
      ),
      runtimeDir: resolveDirectory(
        explicit: socketDir, environmentValue: environment[Environment.runtimeDir],
        production: productionPaths.runtimeDir, developmentValue: development.runtimeDir,
        productionExists: fileExists(productionPaths.daemonSocket.path(percentEncoded: false))
      )
    )
  }

  private static func resolveDirectory(
    explicit: String?, environmentValue: String?, production: URL, developmentValue: URL,
    productionExists: Bool
  ) -> URL {
    if let explicit, !explicit.isEmpty { return URL(fileURLWithPath: explicit, isDirectory: true) }
    if let environmentValue, !environmentValue.isEmpty {
      return URL(fileURLWithPath: environmentValue, isDirectory: true)
    }
    return productionExists ? production : developmentValue
  }
}
