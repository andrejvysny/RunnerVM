import GRDB

public protocol AuditRepository: Sendable {
  func record(kind: String, actor: String, resourceType: String?, resourceId: String?, detail: String?) async throws
}

public final class GRDBAuditRepository: AuditRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func record(kind: String, actor: String, resourceType: String?, resourceId: String?, detail: String?) async throws {
    try await db.write { db in
      let event = AuditEventRecord(
        id: .generateID(), kind: kind, actor: actor, resourceType: resourceType, resourceId: resourceId,
        detailJson: detail, createdAt: .now
      )
      try DatabaseErrorMapper.run(entity: "audit_events") { try event.insert(db) }
    }
  }
}
