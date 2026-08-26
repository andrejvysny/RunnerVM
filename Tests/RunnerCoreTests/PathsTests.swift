import Foundation
import RunnerCore
import Testing

@Suite struct RunnerPathsTests {
  /// Directory URLs carry `directoryHint: .isDirectory`, so `path()` renders a trailing slash.
  /// Tests compare the plain filesystem path.
  private static func fsPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  static let instance = InstanceID(rawValue: "a71c92e4-6b1f-4c2e-9c8d-2f0f9a1b3c4d")

  @Test func productionLayoutMatchesTheSpec() {
    let paths = RunnerPaths.production()
    #expect(Self.fsPath(paths.rootDir) == "/Library/Application Support/RunnerVM")
    #expect(Self.fsPath(paths.stateDir)
      == "/Library/Application Support/RunnerVM/state")
    #expect(Self.fsPath(paths.imagesDir)
      == "/Library/Application Support/RunnerVM/images")
    #expect(Self.fsPath(paths.instancesDir)
      == "/Library/Application Support/RunnerVM/instances")
    #expect(Self.fsPath(paths.logsDir)
      == "/Library/Application Support/RunnerVM/logs")
    #expect(paths.databaseURL.path(percentEncoded: false)
      == "/Library/Application Support/RunnerVM/state/runnerd.sqlite3")
    #expect(Self.fsPath(paths.socketDir) == "/var/run/runnervm")
    #expect(paths.daemonSocket.path(percentEncoded: false) == "/var/run/runnervm/runnerd.sock")
  }

  @Test func developmentLayoutIsUserScopedWithShortSocketDir() {
    let paths = RunnerPaths.development(uid: 501, home: URL(fileURLWithPath: "/Users/dev"))
    #expect(Self.fsPath(paths.rootDir)
      == "/Users/dev/Library/Application Support/RunnerVM")
    #expect(paths.databaseURL.path(percentEncoded: false)
      == "/Users/dev/Library/Application Support/RunnerVM/state/runnerd.sqlite3")
    #expect(Self.fsPath(paths.socketDir) == "/tmp/runnervm-501")
    #expect(paths.daemonSocket.path(percentEncoded: false) == "/tmp/runnervm-501/runnerd.sock")
  }

  @Test func socketsUseTheEightCharacterShortID() {
    let paths = RunnerPaths.production()
    #expect(RunnerPaths.shortID(Self.instance) == "a71c92e4")
    #expect(paths.workerSocket(Self.instance).path(percentEncoded: false)
      == "/var/run/runnervm/vm-a71c92e4.sock")
    #expect(paths.agentSocket(Self.instance).path(percentEncoded: false)
      == "/var/run/runnervm/vm-a71c92e4-agent.sock")
  }

  @Test func instanceDirUsesTheFullID() {
    #expect(Self.fsPath(RunnerPaths.production().instanceDir(Self.instance))
      == "/Library/Application Support/RunnerVM/instances/\(Self.instance.rawValue)")
  }

  @Test func shippedLayoutsAreWithinTheSunPathBudget() throws {
    try RunnerPaths.production().validateSocketPathLengths()
    try RunnerPaths.development(uid: 501, home: URL(fileURLWithPath: "/Users/dev")).validateSocketPathLengths()
    // Even an unusually long home directory is safe, because dev sockets live under /tmp.
    let longHome = URL(fileURLWithPath: "/Users/" + String(repeating: "d", count: 180))
    try RunnerPaths.development(uid: 501, home: longHome).validateSocketPathLengths()
  }

  @Test func rejectsRuntimeDirectoriesThatBlowTheSunPathBudget() {
    let paths = RunnerPaths(
      rootDir: URL(fileURLWithPath: "/tmp/root"),
      runtimeDir: URL(fileURLWithPath: "/tmp/" + String(repeating: "s", count: 96))
    )
    #expect(throws: ConfigurationError.self) { try paths.validateSocketPathLengths() }
  }

  @Test func reportsTheOffendingPathAndLimit() throws {
    let runtime = URL(fileURLWithPath: "/tmp/" + String(repeating: "s", count: 96))
    let paths = RunnerPaths(rootDir: URL(fileURLWithPath: "/tmp/root"), runtimeDir: runtime)
    let error = #expect(throws: ConfigurationError.self) { try paths.validateSocketPathLengths() }
    let unwrapped = try #require(error)
    guard case .socketPathTooLong(let path, let bytes, let limit) = unwrapped else {
      Issue.record("unexpected error \(unwrapped)")
      return
    }
    #expect(path.hasPrefix(runtime.path(percentEncoded: false)))
    #expect(bytes > limit)
    #expect(limit == RunnerPaths.socketPathLimit)
    #expect(unwrapped.code == "SOCKET_PATH_TOO_LONG")
  }

  @Test func theLongestSyntheticSocketIsTheBoundaryThatIsChecked() throws {
    // 100 - len("/vm-ffffffff-agent.sock") == 77 characters of runtime dir (incl. leading "/") are still fine.
    let ok = RunnerPaths(
      rootDir: URL(fileURLWithPath: "/tmp/root"),
      runtimeDir: URL(fileURLWithPath: "/" + String(repeating: "r", count: 76))
    )
    try ok.validateSocketPathLengths()
    let tooLong = RunnerPaths(
      rootDir: URL(fileURLWithPath: "/tmp/root"),
      runtimeDir: URL(fileURLWithPath: "/" + String(repeating: "r", count: 78))
    )
    #expect(throws: ConfigurationError.self) { try tooLong.validateSocketPathLengths() }
  }
}
