import GRDB
import RunnerCore

public protocol JobSummaryRepository: Sendable {
  func insert(_ summary: JobSummaryRecord) async throws
  /// All summaries for one session; append-only, so there is usually exactly one.
  func list(session: RunnerSessionID?) async throws -> [JobSummaryRecord]
}

public final class GRDBJobSummaryRepository: JobSummaryRepository, Sendable {
  private let db: RunnerDatabase

  public init(db: RunnerDatabase) {
    self.db = db
  }

  public func insert(_ summary: JobSummaryRecord) async throws {
    try await db.write { db in
      try DatabaseErrorMapper.run(entity: "job_summaries") { try summary.insert(db) }
    }
  }

  public func list(session: RunnerSessionID?) async throws -> [JobSummaryRecord] {
    try await db.read { db in
      guard let session else { return try JobSummaryRecord.fetchAll(db) }
      return try JobSummaryRecord
        .filter(Column("runner_session_id") == session.rawValue)
        .fetchAll(db)
    }
  }
}
