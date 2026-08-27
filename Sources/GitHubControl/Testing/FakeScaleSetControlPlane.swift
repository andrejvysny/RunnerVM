import Foundation
import RunnerCore
import Synchronization

/// A scripted error the fake can be told to throw. Deliberately its own `Sendable` type: the
/// fake's state lives in a `Mutex`, and `any Error` is not `Sendable`.
public struct FakeScaleSetError: Error, Sendable, Hashable, CustomStringConvertible {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var description: String { "FakeScaleSetError(\(message))" }
}

/// Protocol-level stand-in for `ScaleSetControlPlane` (spec §50).
///
/// Test support shipped in the product module for the same reason `FakeGitHubServer` and
/// `FakeGuestAgent` are: SwiftPM test targets cannot import each other. Nothing in the daemon may
/// construct one.
///
/// Unlike `FakeGitHubServer` this fakes the *protocol*, not the transport: the real Actions
/// message-session wire format is the other implementation's business, and a component test of the
/// orchestrator should fail for orchestration reasons only.
public final class FakeScaleSetControlPlane: ScaleSetControlPlane, Sendable {
  public struct Options: Sendable {
    /// How often an otherwise-empty `getMessage` re-checks the queue. The real client long-polls
    /// for ~50 s; this keeps the same "blocks until there is something" shape without a timer.
    public var pollInterval: Duration = .milliseconds(2)
    public init() {}
  }

  public struct EnsureCall: Sendable, Hashable {
    public var scope: String
    public var name: String
    public var runnerGroupID: Int64
    public var labels: [String]
    public var disableUpdate: Bool
  }

  public struct GetMessageCall: Sendable, Hashable {
    public var scaleSetID: Int64
    public var sessionID: String
    public var lastMessageID: Int64
    public var maxCapacity: Int
  }

  public struct JITCall: Sendable, Hashable {
    public var scaleSetID: Int64
    public var runnerName: String
    public var workFolder: String
  }

  private struct State {
    var nextScaleSetID: Int64 = 1_000
    var nextMessageID: Int64 = 1
    var nextRunnerID: Int64 = 5_000
    var nextSession = 1
    var infos: [Int64: ScaleSetInfo] = [:]
    var idsByKey: [String: Int64] = [:]
    var statistics: [Int64: ScaleSetStatistics] = [:]
    var queues: [Int64: [ScaleSetMessage]] = [:]
    var sessions: [String: Int64] = [:]
    var openSessions: Set<String> = []
    var ensureCalls: [EnsureCall] = []
    var getMessageCalls: [GetMessageCall] = []
    var jitCalls: [JITCall] = []
    var acquireCalls: [[Int64]] = []
    var acquiredIDs: [Int64] = []
    var refusedIDs: Set<Int64> = []
    var deletedMessages: [Int64] = []
    var removedRunners: [Int64] = []
    /// Registrations by runner name, so a lookup by name answers the way the Actions service does.
    var runnersByName: [String: Int64] = [:]
    var pollFailures: [Int64: [FakeScaleSetError]] = [:]
    var ensureFailure: FakeScaleSetError?
    var jitFailure: FakeScaleSetError?
    var closed = false
  }

  private let state = Mutex(State())
  private let options: Options

  public init(options: Options = Options()) {
    self.options = options
  }

  // MARK: - Scripting

  /// Seeds the statistics a session reports and every message carries by default.
  public func setStatistics(_ statistics: ScaleSetStatistics, scaleSetID: Int64) {
    state.withLock { $0.statistics[scaleSetID] = statistics }
  }

  /// Queues one `RunnerScaleSetJobMessages` message. Returns the id it was given.
  @discardableResult
  public func enqueue(
    scaleSetID: Int64, jobs: [ScaleSetJobMessage] = [], statistics: ScaleSetStatistics? = nil,
    messageID: Int64? = nil
  ) -> Int64 {
    state.withLock { state in
      let id = messageID ?? state.nextMessageID
      state.nextMessageID = max(state.nextMessageID, id) + 1
      if let statistics { state.statistics[scaleSetID] = statistics }
      let message = ScaleSetMessage(
        messageId: id, messageType: ScaleSetMessage.jobMessagesType,
        body: Self.encode(jobs), statistics: statistics ?? state.statistics[scaleSetID],
        jobMessages: jobs)
      state.queues[scaleSetID, default: []].append(message)
      return id
    }
  }

  /// Pretends the scale set already holds a registration under `name` — the state a daemon that
  /// died around `generate-jitconfig` leaves behind.
  public func seedRunner(id: Int64, name: String) {
    state.withLock { $0.runnersByName[name] = id }
  }

  /// The next `getMessage` on `scaleSetID` throws instead of answering.
  public func failNextPoll(scaleSetID: Int64, _ message: String) {
    state.withLock { $0.pollFailures[scaleSetID, default: []].append(FakeScaleSetError(message)) }
  }

  public func failEnsureScaleSet(_ message: String?) {
    state.withLock { $0.ensureFailure = message.map(FakeScaleSetError.init) }
  }

  public func failJITConfig(_ message: String?) {
    state.withLock { $0.jitFailure = message.map(FakeScaleSetError.init) }
  }

  /// Request ids `acquireJobs` must report as *not* acquired (another host won them).
  public func refuseAcquisition(of ids: [Int64]) {
    state.withLock { $0.refusedIDs.formUnion(ids) }
  }

  /// Unblocks every waiting `getMessage` with "no message". Call before tearing a test down.
  public func close() {
    state.withLock { $0.closed = true }
  }

  // MARK: - Observation

  public func ensureCalls() -> [EnsureCall] { state.withLock { $0.ensureCalls } }
  public func getMessageCalls() -> [GetMessageCall] { state.withLock { $0.getMessageCalls } }
  public func jitCalls() -> [JITCall] { state.withLock { $0.jitCalls } }
  public func acquireCalls() -> [[Int64]] { state.withLock { $0.acquireCalls } }
  public func acquiredIDs() -> [Int64] { state.withLock { $0.acquiredIDs } }
  public func deletedMessageIDs() -> [Int64] { state.withLock { $0.deletedMessages } }
  public func removedRunners() -> [Int64] { state.withLock { $0.removedRunners } }
  public func openSessionCount() -> Int { state.withLock { $0.openSessions.count } }
  public func scaleSetID(name: String, scope: GitHubScope) -> Int64? {
    state.withLock { $0.idsByKey[Self.key(scope: scope, name: name)] }
  }

  /// The maximum capacity the caller most recently advertised for `scaleSetID`.
  public func lastAdvertisedCapacity(scaleSetID: Int64) -> Int? {
    state.withLock { $0.getMessageCalls.last { $0.scaleSetID == scaleSetID }?.maxCapacity }
  }

  // MARK: - ScaleSetControlPlane

  public func ensureScaleSet(
    scope: GitHubScope, name: String, runnerGroupID: Int64, labels: [String], disableUpdate: Bool
  ) async throws -> ScaleSetInfo {
    try state.withLock { state in
      state.ensureCalls.append(
        EnsureCall(
          scope: scope.description, name: name, runnerGroupID: runnerGroupID, labels: labels,
          disableUpdate: disableUpdate))
      if let failure = state.ensureFailure { throw failure }
      let key = Self.key(scope: scope, name: name)
      if let id = state.idsByKey[key], let info = state.infos[id] { return info }
      let id = state.nextScaleSetID
      state.nextScaleSetID += 1
      let info = ScaleSetInfo(
        id: id, name: name, runnerGroupId: runnerGroupID,
        labels: labels.map { ScaleSetLabel(name: $0) },
        statistics: state.statistics[id])
      state.idsByKey[key] = id
      state.infos[id] = info
      return info
    }
  }

  public func getScaleSet(
    scope: GitHubScope, runnerGroupID: Int64, name: String
  ) async throws -> ScaleSetInfo? {
    state.withLock { state in
      state.idsByKey[Self.key(scope: scope, name: name)].flatMap { state.infos[$0] }
    }
  }

  public func deleteScaleSet(scope: GitHubScope, id: Int64) async throws {
    state.withLock { state in
      state.infos[id] = nil
      state.idsByKey = state.idsByKey.filter { $0.value != id }
    }
  }

  public func openSession(
    scope: GitHubScope, scaleSetID: Int64, owner: String
  ) async throws -> any ScaleSetSession {
    let sessionID = state.withLock { state -> String in
      let id = "fake-session-\(state.nextSession)"
      state.nextSession += 1
      state.sessions[id] = scaleSetID
      state.openSessions.insert(id)
      return id
    }
    return FakeScaleSetSession(
      plane: self, sessionID: sessionID, scaleSetID: scaleSetID, owner: owner)
  }

  public func generateJITConfig(
    scope: GitHubScope, scaleSetID: Int64, runnerName: String, workFolder: String
  ) async throws -> JITRunnerConfig {
    try state.withLock { state in
      state.jitCalls.append(
        JITCall(scaleSetID: scaleSetID, runnerName: runnerName, workFolder: workFolder))
      if let failure = state.jitFailure { throw failure }
      let id = state.nextRunnerID
      state.nextRunnerID += 1
      state.runnersByName[runnerName] = id
      return JITRunnerConfig(
        runnerID: id, runnerName: runnerName,
        encodedJITConfig: "FAKESCALESETJIT-\(scaleSetID)-\(id)")
    }
  }

  public func runner(scope: GitHubScope, id: Int64) async throws -> ScaleSetRunnerReference? {
    state.withLock { state in
      state.removedRunners.contains(id)
        ? nil
        : ScaleSetRunnerReference(id: id, name: "runner-\(id)", runnerScaleSetId: 0)
    }
  }

  public func runner(scope: GitHubScope, name: String) async throws -> ScaleSetRunnerReference? {
    state.withLock { state -> ScaleSetRunnerReference? in
      guard let id = state.runnersByName[name], !state.removedRunners.contains(id) else {
        return nil
      }
      return ScaleSetRunnerReference(id: id, name: name, runnerScaleSetId: 0)
    }
  }

  public func ensureRunnerRemoved(scope: GitHubScope, runnerID: Int64) async throws {
    state.withLock { $0.removedRunners.append(runnerID) }
  }

  // MARK: - Session-side internals

  func sessionInfo(sessionID: String, owner: String) -> ScaleSetSessionInfo {
    state.withLock { state in
      let scaleSetID = state.sessions[sessionID] ?? 0
      return ScaleSetSessionInfo(
        sessionId: sessionID, ownerName: owner, scaleSetId: scaleSetID,
        statistics: state.statistics[scaleSetID])
    }
  }

  /// Blocks until a message with an id above `lastMessageID` is queued, the session is closed, or
  /// the calling task is cancelled — the shape a 50-second long poll has from the caller's side.
  func nextMessage(
    sessionID: String, scaleSetID: Int64, lastMessageID: Int64, maxCapacity: Int
  ) async throws -> ScaleSetMessage? {
    state.withLock { state in
      state.getMessageCalls.append(
        GetMessageCall(
          scaleSetID: scaleSetID, sessionID: sessionID, lastMessageID: lastMessageID,
          maxCapacity: maxCapacity))
    }
    if let failure = state.withLock({ $0.pollFailures[scaleSetID]?.isEmpty == false
      ? $0.pollFailures[scaleSetID]!.removeFirst() : nil })
    {
      throw failure
    }
    while true {
      try Task.checkCancellation()
      let outcome = state.withLock { state -> ScaleSetMessage?? in
        if let message = state.queues[scaleSetID]?.first(where: { $0.messageId > lastMessageID }) {
          return .some(message)
        }
        return state.closed || !state.openSessions.contains(sessionID) ? .some(nil) : nil
      }
      if let outcome { return outcome }
      try await Task.sleep(for: options.pollInterval)
    }
  }

  func deleteMessage(sessionID: String, scaleSetID: Int64, id: Int64) {
    state.withLock { state in
      state.deletedMessages.append(id)
      state.queues[scaleSetID]?.removeAll { $0.messageId == id }
    }
  }

  func acquireJobs(scaleSetID: Int64, requestIDs: [Int64]) -> [Int64] {
    state.withLock { state in
      state.acquireCalls.append(requestIDs)
      let granted = requestIDs.filter { !state.refusedIDs.contains($0) }
      state.acquiredIDs.append(contentsOf: granted)
      return granted
    }
  }

  func closeSession(_ sessionID: String) {
    state.withLock { $0.openSessions.remove(sessionID) }
  }

  // MARK: - Helpers

  private static func key(scope: GitHubScope, name: String) -> String {
    "\(scope.description)#\(name)"
  }

  private static func encode(_ jobs: [ScaleSetJobMessage]) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(jobs), let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
  }
}

/// One open message session against `FakeScaleSetControlPlane`. Holds no mutable state of its own;
/// everything lives behind the plane's lock, so the session is trivially `Sendable`.
public final class FakeScaleSetSession: ScaleSetSession, Sendable {
  private let plane: FakeScaleSetControlPlane
  private let sessionID: String
  private let scaleSetID: Int64
  private let owner: String

  init(plane: FakeScaleSetControlPlane, sessionID: String, scaleSetID: Int64, owner: String) {
    self.plane = plane
    self.sessionID = sessionID
    self.scaleSetID = scaleSetID
    self.owner = owner
  }

  public var info: ScaleSetSessionInfo {
    plane.sessionInfo(sessionID: sessionID, owner: owner)
  }

  public func getMessage(lastMessageID: Int64, maxCapacity: Int) async throws -> ScaleSetMessage? {
    try await plane.nextMessage(
      sessionID: sessionID, scaleSetID: scaleSetID, lastMessageID: lastMessageID,
      maxCapacity: maxCapacity)
  }

  public func deleteMessage(id: Int64) async throws {
    plane.deleteMessage(sessionID: sessionID, scaleSetID: scaleSetID, id: id)
  }

  public func acquireJobs(requestIDs: [Int64]) async throws -> [Int64] {
    plane.acquireJobs(scaleSetID: scaleSetID, requestIDs: requestIDs)
  }

  public func close() async throws {
    plane.closeSession(sessionID)
  }
}
