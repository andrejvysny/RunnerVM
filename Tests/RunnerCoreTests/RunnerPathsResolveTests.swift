import Foundation
import RunnerCore
import Testing

/// The precedence matrix behind production socket/layout auto-discovery: explicit flag beats the
/// environment, which beats an existing production install, which beats the developer layout.
/// Every disk probe is injected, so none of this depends on whether the machine running the tests
/// actually has `/var/run/runnervm` or `/Library/Application Support/RunnerVM`.
@Suite struct RunnerPathsResolveTests {
  private static let development = RunnerPaths.development(
    uid: 501, home: URL(fileURLWithPath: "/Users/dev"))
  private static let production = RunnerPaths.production()

  private static func fsPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// Nothing exists on this host.
  private static func nothingExists(_ path: String) -> Bool { false }

  /// A full production install: state root and daemon socket both present.
  private static func productionExists(_ path: String) -> Bool {
    path == production.rootDir.path(percentEncoded: false)
      || path == production.daemonSocket.path(percentEncoded: false)
      || path == fsPath(production.rootDir)
  }

  // MARK: resolveSocket

  @Test func explicitSocketBeatsEverything() {
    let url = RunnerPaths.resolveSocket(
      explicit: "/tmp/flag.sock",
      environment: [RunnerPaths.Environment.socket: "/tmp/env.sock"],
      development: Self.development, fileExists: Self.productionExists(_:))
    #expect(url.path(percentEncoded: false) == "/tmp/flag.sock")
  }

  @Test func environmentSocketBeatsAnInstalledProduction() {
    let url = RunnerPaths.resolveSocket(
      explicit: nil, environment: [RunnerPaths.Environment.socket: "/tmp/env.sock"],
      development: Self.development, fileExists: Self.productionExists(_:))
    #expect(url.path(percentEncoded: false) == "/tmp/env.sock")
  }

  /// The regression this whole resolver exists for: `runnerctl` on a host with a LaunchDaemon
  /// installed used to probe the developer socket and report the daemon unreachable.
  @Test func anExistingProductionSocketBeatsTheDevelopmentLayout() {
    let url = RunnerPaths.resolveSocket(
      explicit: nil, environment: [:], development: Self.development,
      fileExists: Self.productionExists(_:))
    #expect(url.path(percentEncoded: false) == "/var/run/runnervm/runnerd.sock")
  }

  @Test func developmentSocketIsTheLastResort() {
    let url = RunnerPaths.resolveSocket(
      explicit: nil, environment: [:], development: Self.development,
      fileExists: Self.nothingExists(_:))
    #expect(url.path(percentEncoded: false) == "/tmp/runnervm-501/runnerd.sock")
  }

  /// An empty flag or an empty variable is "unset", not "the socket at path ''".
  @Test func emptyOverridesAreIgnored() {
    let url = RunnerPaths.resolveSocket(
      explicit: "", environment: [RunnerPaths.Environment.socket: ""],
      development: Self.development, fileExists: Self.nothingExists(_:))
    #expect(url.path(percentEncoded: false) == "/tmp/runnervm-501/runnerd.sock")
  }

  // MARK: socketOverride

  @Test func socketOverrideIsNilWithoutAFlagOrVariable() {
    #expect(RunnerPaths.socketOverride(explicit: nil, environment: [:]) == nil)
    #expect(RunnerPaths.socketOverride(explicit: "", environment: [:]) == nil)
    #expect(
      RunnerPaths.socketOverride(
        explicit: nil, environment: [RunnerPaths.Environment.socket: "/tmp/env.sock"])?
        .path(percentEncoded: false) == "/tmp/env.sock")
  }

  // MARK: resolveRoots

  @Test func explicitDirectoriesBeatEverything() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: "/srv/state", socketDir: "/srv/run",
      environment: [
        RunnerPaths.Environment.stateDir: "/env/state",
        RunnerPaths.Environment.runtimeDir: "/env/run",
      ],
      development: Self.development, fileExists: Self.productionExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/srv/state")
    #expect(Self.fsPath(paths.runtimeDir) == "/srv/run")
  }

  @Test func environmentDirectoriesBeatAnInstalledProduction() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: nil, socketDir: nil,
      environment: [
        RunnerPaths.Environment.stateDir: "/env/state",
        RunnerPaths.Environment.runtimeDir: "/env/run",
      ],
      development: Self.development, fileExists: Self.productionExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/env/state")
    #expect(Self.fsPath(paths.runtimeDir) == "/env/run")
  }

  @Test func anExistingProductionLayoutBeatsDevelopment() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: nil, socketDir: nil, environment: [:], development: Self.development,
      fileExists: Self.productionExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/Library/Application Support/RunnerVM")
    #expect(Self.fsPath(paths.runtimeDir) == "/var/run/runnervm")
  }

  @Test func developmentLayoutIsTheLastResort() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: nil, socketDir: nil, environment: [:], development: Self.development,
      fileExists: Self.nothingExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/Users/dev/Library/Application Support/RunnerVM")
    #expect(Self.fsPath(paths.runtimeDir) == "/tmp/runnervm-501")
  }

  /// Each component probes its own path, so a half-installed host (state laid out, daemon never
  /// started) still finds its state root instead of silently falling back for both.
  @Test func componentsResolveIndependently() {
    let onlyRootExists: (String) -> Bool = { $0 == Self.production.rootDir.path(percentEncoded: false) }
    let paths = RunnerPaths.resolveRoots(
      stateDir: nil, socketDir: nil, environment: [:], development: Self.development,
      fileExists: onlyRootExists)
    #expect(Self.fsPath(paths.rootDir) == "/Library/Application Support/RunnerVM")
    #expect(Self.fsPath(paths.runtimeDir) == "/tmp/runnervm-501")
  }

  /// A flag on one component must not drag the other one along with it.
  @Test func oneExplicitDirectoryDoesNotOverrideTheOther() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: "/srv/state", socketDir: nil, environment: [:], development: Self.development,
      fileExists: Self.productionExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/srv/state")
    #expect(Self.fsPath(paths.runtimeDir) == "/var/run/runnervm")
  }

  @Test func emptyDirectoryOverridesAreIgnored() {
    let paths = RunnerPaths.resolveRoots(
      stateDir: "", socketDir: "",
      environment: [
        RunnerPaths.Environment.stateDir: "", RunnerPaths.Environment.runtimeDir: "",
      ],
      development: Self.development, fileExists: Self.nothingExists(_:))
    #expect(Self.fsPath(paths.rootDir) == "/Users/dev/Library/Application Support/RunnerVM")
    #expect(Self.fsPath(paths.runtimeDir) == "/tmp/runnervm-501")
  }
}
