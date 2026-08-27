import Foundation
import GitHubControl
import Logging
import Metrics
import GuestControl
import Persistence
import RunnerCore
import Synchronization
import Testing

@testable import Orchestration

/// `KeychainItemStore` with no keychain behind it: the credential tests must not prompt, unlock
/// or leave anything in the developer's login keychain.
final class InMemoryKeychain: KeychainItemStore, Sendable {
  private let items = Mutex<[String: Data]>([:])

  func password(service: String, account: String) throws -> Data? {
    items.withLock { $0["\(service)/\(account)"] }
  }

  func setPassword(_ data: Data, service: String, account: String) throws {
    items.withLock { $0["\(service)/\(account)"] = data }
  }

  func deletePassword(service: String, account: String) throws {
    items.withLock { $0["\(service)/\(account)"] = nil }
  }
}

extension M2Harness {
  static let token = "ghp_harness000000000000000000000000000000"
  /// Distinctive on purpose: the secret-boundary test greps the whole temp tree for it.
  static let jitSecret = "RVMJITSECRET0000deadbeef0000RVMJITSECRET"
  static let runnerID: Int64 = 42

  static let runnersPath = "/repos/acme/app/actions/runners"
  static let repositoryPath = "/repos/acme/app"
  static var jitPath: String { runnersPath + "/generate-jitconfig" }
  static var runnerPath: String { runnersPath + "/\(runnerID)" }
  static let userPath = "/user"

  /// The routes a healthy private repository scope answers, plus the JIT registration.
  func stubGitHub(
    login: String = "octocat", visibility: String = "private", isPrivate: Bool = true,
    runners: String = "[]"
  ) {
    github.stub(.get, Self.userPath, .json("{\"login\":\"\(login)\"}"))
    github.stub(
      .get, Self.runnersPath, .json("{\"total_count\":0,\"runners\":\(runners)}"))
    github.stub(
      .get, Self.repositoryPath,
      .json("{\"private\":\(isPrivate),\"visibility\":\"\(visibility)\"}"))
    stubJIT()
    github.stub(.delete, Self.runnerPath, .empty(204))
  }

  func stubJIT(id: Int64 = M2Harness.runnerID, name: String = "rvm-jit-runner") {
    github.stub(
      .post, Self.jitPath,
      .json("""
        {"runner":{"id":\(id),"name":"\(name)","os":"linux","status":"offline","busy":false,\
        "labels":[]},"encoded_jit_config":"\(M2Harness.jitSecret)"}
        """))
  }

  /// Brings one instance of `linux` all the way to `idle` behind a scripted guest agent.
  func idleInstance(
    script: FakeGuestAgent.Script = FakeGuestAgent.Script()
  ) async throws -> (InstanceRecord, FakeGuestAgent) {
    try await importLinuxImage()
    let record = try await instances.create(profileName: "linux")
    let agent = try await startGuestAgent(for: record.id, script: script)
    try await awaitInstance(record.id, state: .idle)
    return (try await self.record(record.id), agent)
  }

  func session(_ id: RunnerSessionID) async throws -> RunnerSessionRecord {
    try #require(try await GRDBRunnerSessionRepository(db: database).get(id: id))
  }

  func jobSummaries() async throws -> [JobSummaryRecord] {
    try await GRDBJobSummaryRepository(db: database).list(session: nil)
  }

  func operations() async throws -> [OperationRecord] {
    try await GRDBOperationRepository(db: database).list(state: nil)
  }

  /// Waits for the background observer to park the session in a terminal state.
  @discardableResult
  func awaitTerminal(_ id: RunnerSessionID) async throws -> RunnerSessionRecord {
    try await awaitSession(id, "session \(id.rawValue) to reach a terminal state") { $0.isTerminal }
  }

  /// Returns once the session has been recorded in `state` (or any later state).
  @discardableResult
  func awaitSession(_ id: RunnerSessionID, state: RunnerSessionState) async throws -> RunnerSessionRecord {
    try await awaitSession(id, "session \(id.rawValue) to reach \(state.rawValue)") { $0 == state }
  }

  /// Event-driven: subscribes to the lifecycle stream, then checks the row (so a transition that
  /// already happened is not missed), then consumes `session.transition` events until one lands
  /// in a state the predicate accepts. Every transition is recorded *after* its row is written.
  @discardableResult
  func awaitSession(
    _ id: RunnerSessionID, _ description: String,
    _ accept: @escaping @Sendable (RunnerSessionState) -> Bool
  ) async throws -> RunnerSessionRecord {
    let stream = await events.subscribe()
    let sessions = GRDBRunnerSessionRepository(db: database)
    if let current = try await sessions.get(id: id), accept(current.state) { return current }
    return try await withHangGuard(description) {
      for await event in stream
      where event.name == LifecycleEventLog.sessionTransition && event.fields.session == id {
        guard let raw = event.fields.to, let state = RunnerSessionState(rawValue: raw),
              accept(state) else { continue }
        return try #require(try await sessions.get(id: id))
      }
      throw WaitTimeout(description: "event stream closed while waiting for \(description)")
    }
  }

  /// Instance-row counterpart of `awaitSession`.
  @discardableResult
  func awaitInstance(_ id: InstanceID, state: InstanceState) async throws -> InstanceRecord {
    try await awaitInstance(id, "instance \(id.rawValue) to reach \(state.rawValue)") { $0 == state }
  }

  @discardableResult
  func awaitInstance(
    _ id: InstanceID, _ description: String,
    _ accept: @escaping @Sendable (InstanceState) -> Bool
  ) async throws -> InstanceRecord {
    let stream = await events.subscribe()
    if let current = try await instanceRows.get(id: id), accept(current.state) { return current }
    let rows = instanceRows
    return try await withHangGuard(description) {
      for await event in stream
      where event.name == LifecycleEventLog.instanceTransition && event.fields.instance == id {
        guard let raw = event.fields.to, let state = InstanceState(rawValue: raw), accept(state)
        else { continue }
        return try #require(try await rows.get(id: id))
      }
      throw WaitTimeout(description: "event stream closed while waiting for \(description)")
    }
  }

  /// Marks the scope healthy the way `config.apply` would, without a live probe.
  func markScopeHealthy(_ name: String = "test", runnerGroupID: Int64 = 1) async throws {
    let scopes = GRDBScopeRepository(db: database)
    var record = try #require(try await scopes.get(name: name))
    record.health = "healthy"
    record.runnerGroupId = runnerGroupID
    try await scopes.upsert(record)
  }
}

extension M2Harness {
  /// `service()` with a real YAML parser, for the tests that go through `config.apply`.
  func service(
    parseConfig: @escaping @Sendable (String) throws -> RunnerConfiguration
  ) -> DaemonServiceImpl {
    DaemonServiceImpl(
      paths: paths, hostId: hostId, database: database, images: images, instances: instances,
      supervisor: supervisor,
      applier: ConfigApplier(store: GRDBConfigStore(db: database), stateDir: paths.stateDir),
      reconciler: Reconciler(logger: Logger(label: "test")), parseConfig: parseConfig,
      probe: M2Harness.probe(), startedAt: Date(), actorName: "test", gateway: gateway,
      scopeHealth: scopeHealth, runnerVersions: runnerVersions, runners: runners,
      metrics: metrics, logger: Logger(label: "test"))
  }
}

/// Every file under `root` whose bytes contain `needle`. Used to prove the JIT secret never
/// reached disk (spec §36, §128).
func filesContaining(_ needle: String, under root: URL) -> [String] {
  let manager = FileManager.default
  guard let enumerator = manager.enumerator(
    at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [],
    errorHandler: { _, _ in true })
  else { return [] }
  var hits: [String] = []
  let pattern = Data(needle.utf8)
  for case let url as URL in enumerator {
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
          let data = try? Data(contentsOf: url), data.range(of: pattern) != nil
    else { continue }
    hits.append(url.path(percentEncoded: false))
  }
  return hits
}
