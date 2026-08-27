import RPC

/// The daemon protocol catalogue (`Proto/daemon_api.md`). Every method in the document appears
/// here even when M1 does not implement it yet, so `runnerctl` and the server agree on the name
/// and class before the handler exists.
public enum DaemonMethod: String, Sendable, Hashable, CaseIterable, Codable {
  case systemStatus = "system.status"
  case systemDoctor = "system.doctor"
  case systemReconcile = "system.reconcile"
  case systemDrain = "system.drain"
  case systemResume = "system.resume"
  case systemOffline = "system.offline"
  case systemShutdown = "system.shutdown"
  case systemVersion = "system.version"

  case configGet = "config.get"
  case configValidate = "config.validate"
  case configApply = "config.apply"

  case profileList = "profile.list"
  case profileGet = "profile.get"
  case scopeList = "scope.list"
  case scopeGet = "scope.get"

  case imageList = "image.list"
  case imageGet = "image.get"
  case imageImport = "image.import"
  case imagePull = "image.pull"
  case imagePush = "image.push"
  case imageDelete = "image.delete"
  case imagePrune = "image.prune"
  /// Phase 5 image builder. `runnerd` answers `BUILD_UNAVAILABLE` until it lands.
  case imageBuild = "image.build"
  case buildList = "build.list"
  case buildGet = "build.get"
  case buildLog = "build.log"
  case buildCancel = "build.cancel"

  case registryLogin = "registry.login"
  case registryLogout = "registry.logout"
  case registryStatus = "registry.status"

  case instanceList = "instance.list"
  case instanceGet = "instance.get"
  case instanceCreate = "instance.create"
  case instanceStop = "instance.stop"
  case instanceDelete = "instance.delete"
  case instanceTaint = "instance.taint"
  case instanceExec = "instance.exec"
  case instanceSSHInfo = "instance.sshInfo"
  case instanceMetrics = "instance.metrics"

  case runnerList = "runner.list"
  case runnerGet = "runner.get"

  case scaleSetList = "scaleset.list"

  case authStatus = "auth.status"
  case authLogin = "auth.login"
  case authLogout = "auth.logout"
  case githubTest = "github.test"
  case debugRunJIT = "debug.runJit"
  case debugDemandSet = "debug.demandSet"

  case operationGet = "operation.get"
  case operationList = "operation.list"
  case logsTail = "logs.tail"
  case metricsSnapshot = "metrics.snapshot"

  /// Retry safety, per `Proto/envelope.md`. Callers branch on this, never on the method name.
  public var methodClass: MethodClass {
    switch self {
    case .systemReconcile, .systemDrain, .systemResume, .systemOffline, .systemShutdown,
         .configApply, .imageDelete, .imagePrune, .imagePull, .imagePush,
         .registryLogin, .registryLogout,
         .instanceStop, .instanceDelete, .instanceTaint, .authLogin, .authLogout,
         .debugDemandSet, .buildCancel:
      return .idempotentMutation
    case .imageImport, .instanceCreate, .instanceExec, .debugRunJIT, .imageBuild:
      return .singleShot
    default:
      return .readOnly
    }
  }

  /// Chunked methods; M1 registers them as unary NOT_IMPLEMENTED stubs.
  public var isStreaming: Bool {
    self == .instanceExec || self == .logsTail
  }

  /// The subset with a real handler today. Everything else answers `NOT_IMPLEMENTED`.
  public static let implemented: Set<DaemonMethod> = [
    .systemStatus, .systemVersion,
    .systemDrain, .systemResume, .systemOffline, .systemShutdown, .metricsSnapshot,
    .configGet, .configValidate, .configApply,
    .profileList, .profileGet, .scopeList, .scopeGet,
    .imageList, .imageGet, .imageImport, .imagePull, .imagePush, .imageDelete, .imagePrune,
    .imageBuild, .buildList, .buildGet, .buildLog, .buildCancel,
    .registryLogin, .registryLogout, .registryStatus,
    .instanceList, .instanceGet, .instanceCreate, .instanceStop, .instanceDelete,
    .instanceTaint,
    .instanceExec, .instanceMetrics, .instanceSSHInfo,
    .runnerList, .runnerGet, .scaleSetList,
    .authStatus, .authLogin, .authLogout, .githubTest, .debugRunJIT, .debugDemandSet,
    .operationGet, .operationList,
  ]

  public var isImplemented: Bool { Self.implemented.contains(self) }
}

/// Daemon-specific wire error codes, layered on the shared `RPCErrorCode` set.
public enum DaemonErrorCode {
  /// A catalogued method whose handler lands in a later milestone.
  public static let notImplemented = "NOT_IMPLEMENTED"
  /// The named profile, scope or operation does not exist.
  public static let notFound = "NOT_FOUND"
  /// The daemon parsed the request but the configuration it carries is rejected.
  public static let configRejected = "CONFIG_VALIDATION_FAILED"
}
