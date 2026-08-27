import DaemonAPI
import Foundation
import RunnerCore
import RunnerLogging

/// One JSON object per line in `logs/events.jsonl`: every instance, session and scale-set
/// lifecycle transition, plus every audit event (spec §42, §117).
///
/// Deliberately *not* the same stream as `runnerd.log`. The daemon log is prose with metadata and
/// is filtered by level; this is a fixed-shape record an alerting pipeline can join on without
/// parsing English, and it is never filtered — a transition either happened or it did not.
///
/// Writing is best effort by construction: the underlying ``RotatingFileSink`` drops rather than
/// throws, so a full disk slows nothing down and blocks no state machine.
public actor LifecycleEventLog {
  /// Fields shared by every line. All optional except `ts`/`event`/`host_id`, because a
  /// scale-set transition has no instance and an instance transition has no runner id.
  public struct Fields: Sendable {
    public var instance: InstanceID?
    public var profile: RunnerProfileID?
    public var session: RunnerSessionID?
    public var scaleSetID: String?
    public var githubRunnerID: Int64?
    public var from: String?
    public var to: String?
    public var reason: String?

    public init(
      instance: InstanceID? = nil, profile: RunnerProfileID? = nil, session: RunnerSessionID? = nil,
      scaleSetID: String? = nil, githubRunnerID: Int64? = nil, from: String? = nil,
      to: String? = nil, reason: String? = nil
    ) {
      self.instance = instance
      self.profile = profile
      self.session = session
      self.scaleSetID = scaleSetID
      self.githubRunnerID = githubRunnerID
      self.from = from
      self.to = to
      self.reason = reason
    }
  }

  /// One recorded transition, as handed to in-process subscribers.
  public struct Event: Sendable {
    public let name: String
    public let fields: Fields
  }

  private let hostId: HostID
  private let sink: RotatingFileSink
  private let redactor: Redactor
  private let now: @Sendable () -> Date
  private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

  /// Throws when the file cannot be opened, so wiring can fall back to "no event stream" and log
  /// why instead of silently producing nothing.
  public init(
    url: URL, hostId: HostID, options: RotatingFileSink.Options = RotatingFileSink.Options(),
    redactor: Redactor = .standard, now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    self.hostId = hostId
    self.sink = try RotatingFileSink(url: url, options: options)
    self.redactor = redactor
    self.now = now
  }

  /// In-process fan-out of every recorded event, delivered after the transition it describes has
  /// been persisted. Tests synchronise on lifecycle transitions through this instead of polling
  /// the database on a timer; the daemon itself has no subscribers.
  public func subscribe() -> AsyncStream<Event> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(id) }
    }
    subscribers[id] = continuation
    return stream
  }

  private func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  public func record(_ event: String, _ fields: Fields = Fields()) {
    for continuation in subscribers.values {
      continuation.yield(Event(name: event, fields: fields))
    }
    var payload: [String: Any] = [
      "ts": RFC3339.string(from: now()),
      "event": event,
      "host_id": hostId.rawValue,
    ]
    payload["instance_id"] = fields.instance?.rawValue
    payload["profile_id"] = fields.profile?.rawValue
    payload["runner_session_id"] = fields.session?.rawValue
    payload["scale_set_id"] = fields.scaleSetID
    payload["github_runner_id"] = fields.githubRunnerID
    payload["from"] = fields.from
    payload["to"] = fields.to
    // The only free-text field, so the only one a secret could ride in on.
    payload["reason"] = fields.reason.map { redactor.redact($0) }
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else { return }
    sink.write(line)
  }

  public func droppedLines() -> UInt64 { sink.droppedLines }

  public func close() {
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    sink.close()
  }
}

extension LifecycleEventLog {
  // Event names are API: `docs/logging.md` documents them and shippers key alerts off them.
  public static let instanceTransition = "instance.transition"
  public static let sessionTransition = "session.transition"
  public static let auditEvent = "audit"
  public static let diagnosticsCollected = "instance.diagnostics"
}
