import Foundation
import Logging

/// A `LogHandler` that writes one redacted JSON object per line (spec §42).
///
/// Fields: `timestamp` (RFC3339, fractional seconds, UTC), `level`, `component`
/// (the logger label), `message`, then all metadata flattened as top-level keys.
/// `source` is intentionally omitted. Output goes through an injectable sink so
/// tests can capture lines in memory instead of writing to stderr.
public struct JSONLogHandler: LogHandler {
  public var logLevel: Logger.Level
  public var metadataProvider: Logger.MetadataProvider?
  public var metadata: Logger.Metadata = [:]

  private let component: String
  private let redactor: Redactor
  private let sink: @Sendable (String) -> Void

  /// Default sink: writes to stderr, one line at a time, serialized by a lock so
  /// concurrent log calls never interleave partial lines.
  public static let defaultSink: @Sendable (String) -> Void = { line in StderrSink.shared.write(line) }

  public init(
    label: String,
    logLevel: Logger.Level = .info,
    redactor: Redactor = .standard,
    metadataProvider: Logger.MetadataProvider? = nil,
    sink: @escaping @Sendable (String) -> Void = JSONLogHandler.defaultSink
  ) {
    self.component = label
    self.logLevel = logLevel
    self.redactor = redactor
    self.metadataProvider = metadataProvider
    self.sink = sink
  }

  public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  public func log(event: LogEvent) {
    let merged = Self.mergeMetadata(
      global: LogContext.global, base: metadata, provider: metadataProvider,
      explicit: event.metadata)
    let redactedMetadata = redactor.redact(metadata: merged)

    var payload: [String: Any] = [
      "timestamp": Self.rfc3339(Date()),
      "level": event.level.rawValue,
      "component": component,
      "message": redactor.redact(event.message.description),
    ]
    // Standard fields win over any metadata key that happens to collide with them.
    for (key, value) in redactedMetadata where payload[key] == nil {
      payload[key] = Self.jsonValue(value)
    }

    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else { return }
    sink(line)
  }

  /// Merge order matches swift-log convention, with `LogContext.global` underneath everything:
  /// process-wide context is the base, then handler metadata, then the metadata provider, then
  /// per-call-site metadata.
  private static func mergeMetadata(
    global: Logger.Metadata, base: Logger.Metadata, provider: Logger.MetadataProvider?,
    explicit: Logger.Metadata?
  ) -> Logger.Metadata {
    var merged = global
    if !base.isEmpty { merged.merge(base) { _, new in new } }
    if let provided = provider?.get(), !provided.isEmpty {
      merged.merge(provided) { _, new in new }
    }
    if let explicit, !explicit.isEmpty {
      merged.merge(explicit) { _, new in new }
    }
    return merged
  }

  private static func jsonValue(_ value: Logger.MetadataValue) -> Any {
    switch value {
    case .string(let string): return string
    case .stringConvertible(let convertible): return convertible.description
    case .dictionary(let nested): return nested.mapValues(jsonValue)
    case .array(let values): return values.map(jsonValue)
    }
  }

  /// A fresh formatter per call avoids sharing a non-Sendable `ISO8601DateFormatter`
  /// across concurrent log calls.
  private static func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
  }
}

/// Lock-protected writer to stderr, used as the default output sink.
private final class StderrSink: @unchecked Sendable {
  static let shared = StderrSink()

  private let lock = NSLock()

  func write(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    lock.lock()
    defer { lock.unlock() }
    try? FileHandle.standardError.write(contentsOf: data)
  }
}
