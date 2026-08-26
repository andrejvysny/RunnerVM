import Foundation
import Logging
import Persistence
import RunnerCore
import RunnerLogging

/// Sweeps `logs/instances/<id>/` (spec §74).
///
/// Deliberately separate from `InstanceStore.retentionSweep`, which drops the *disk* directory of
/// a VM that failed to come up: this one deletes the logs a perfectly successful job left behind,
/// long after the instance itself is gone, and it is the only thing that stops `logs/` growing
/// without bound on a busy host.
///
/// A directory whose instance is still live is never touched, whatever its mtime says — a
/// long-running job legitimately produces no writes for hours.
public struct InstanceLogRetention: Sendable {
  private let paths: RunnerPaths
  private let logger: Logger

  public init(paths: RunnerPaths, logger: Logger = Logger(component: .daemon)) {
    self.paths = paths
    self.logger = logger
  }

  @discardableResult
  public func sweep(
    olderThan retention: Duration, keeping live: Set<InstanceID>, now: Date = Date()
  ) -> [InstanceID] {
    guard retention > .zero else { return [] }
    let manager = FileManager.default
    let root = paths.instanceLogsDir
    guard let children = try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    let cutoff = now.addingTimeInterval(-Self.seconds(retention))
    var swept: [InstanceID] = []
    for child in children where !child.lastPathComponent.hasPrefix(".") {
      let id = InstanceID(rawValue: child.lastPathComponent)
      guard !live.contains(id), let modified = Self.newestWrite(in: child), modified < cutoff
      else { continue }
      guard (try? manager.removeItem(at: child)) != nil else { continue }
      swept.append(id)
    }
    if !swept.isEmpty {
      logger.info(
        "instance log directories swept",
        metadata: ["count": .stringConvertible(swept.count)])
    }
    return swept
  }

  /// The newest mtime anywhere in the directory, not the directory's own: a `diag/` written after
  /// the directory was created leaves the parent's mtime older than the evidence inside it.
  private static func newestWrite(in directory: URL) -> Date? {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    var newest = (try? manager.attributesOfItem(atPath: directory.path(percentEncoded: false))[
      .modificationDate] as? Date) ?? nil
    guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: keys) else {
      return newest
    }
    for case let child as URL in walker {
      guard let modified = try? child.resourceValues(forKeys: Set(keys)).contentModificationDate
      else { continue }
      if newest == nil || modified > newest! { newest = modified }
    }
    return newest
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}

/// Mirrors every persisted audit event into `logs/events.jsonl`.
///
/// A decorator rather than an extra call at each `audit.record` site: the audit rows and the event
/// stream must never disagree about what happened, and a decorator makes that structural.
struct EventLoggingAuditRepository: AuditRepository {
  let base: any AuditRepository
  let events: LifecycleEventLog

  func record(
    kind: String, actor: String, resourceType: String?, resourceId: String?, detail: String?
  ) async throws {
    try await base.record(
      kind: kind, actor: actor, resourceType: resourceType, resourceId: resourceId, detail: detail)
    await events.record(
      LifecycleEventLog.auditEvent,
      LifecycleEventLog.Fields(
        instance: resourceType == "instance" ? resourceId.map(InstanceID.init(rawValue:)) : nil,
        from: actor, to: kind, reason: detail))
  }
}
