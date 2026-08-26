import Foundation

/// SQLite-backed store failures, expressed without leaking the database library.
public enum PersistenceError: RunnerError {
  case notFound(entity: String, id: String)
  case conflict(entity: String, reason: String)
  /// A compare-and-swap on (state, generation) lost: another actor moved the row first.
  case staleWrite(entity: String, id: String, expectedState: String, actualState: String)
  case uniqueConstraintViolated(entity: String, field: String)
  case foreignKeyViolated(entity: String, field: String)
  case busy(reason: String)
  case corrupted(reason: String)
  case migrationFailed(version: Int, reason: String)
  case schemaVersionUnsupported(found: Int, supported: Int)
  case encodingFailed(entity: String, cause: (any Error & Sendable)?)

  public var code: String {
    switch self {
    case .notFound: "DB_NOT_FOUND"
    case .conflict: "DB_CONFLICT"
    case .staleWrite: "DB_STALE_WRITE"
    case .uniqueConstraintViolated: "DB_UNIQUE_CONSTRAINT"
    case .foreignKeyViolated: "DB_FOREIGN_KEY"
    case .busy: "DB_BUSY"
    case .corrupted: "DB_CORRUPTED"
    case .migrationFailed: "DB_MIGRATION_FAILED"
    case .schemaVersionUnsupported: "DB_SCHEMA_VERSION_UNSUPPORTED"
    case .encodingFailed: "DB_ENCODING_FAILED"
    }
  }

  public var message: String {
    switch self {
    case .notFound(let entity, let id): "\(entity) \(id) not found"
    case .conflict(let entity, let reason): "\(entity) conflict: \(reason)"
    case .staleWrite(let entity, let id, let expected, let actual):
      "\(entity) \(id) expected state \(expected) but found \(actual)"
    case .uniqueConstraintViolated(let entity, let field): "\(entity).\(field) must be unique"
    case .foreignKeyViolated(let entity, let field): "\(entity).\(field) references a missing row"
    case .busy(let reason): "database busy: \(reason)"
    case .corrupted(let reason): "database corrupted: \(reason)"
    case .migrationFailed(let version, let reason): "migration \(version) failed: \(reason)"
    case .schemaVersionUnsupported(let found, let supported):
      "database schema v\(found) is newer than supported v\(supported)"
    case .encodingFailed(let entity, _): "could not encode \(entity)"
    }
  }

  public var retryable: Bool {
    switch self {
    // Only lock contention and lost CAS races clear by themselves.
    case .busy, .staleWrite: true
    case .notFound, .conflict, .uniqueConstraintViolated, .foreignKeyViolated, .corrupted,
         .migrationFailed, .schemaVersionUnsupported, .encodingFailed:
      false
    }
  }

  public var underlying: (any Error)? {
    if case .encodingFailed(_, let cause) = self { return cause }
    return nil
  }
}
