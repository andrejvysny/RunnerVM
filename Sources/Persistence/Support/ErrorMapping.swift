import GRDB
import RunnerCore

/// Translates raw SQLite constraint failures into `PersistenceError`, so repository callers never
/// need to know GRDB or SQLite result codes exist.
enum DatabaseErrorMapper {
  static func map(_ error: any Error, entity: String) -> any Error {
    guard let dbError = error as? DatabaseError else { return error }
    switch dbError.extendedResultCode {
    case .SQLITE_CONSTRAINT_FOREIGNKEY, .SQLITE_CONSTRAINT_TRIGGER:
      return PersistenceError.foreignKeyViolated(entity: entity, field: dbError.message ?? "unknown")
    case .SQLITE_CONSTRAINT_UNIQUE, .SQLITE_CONSTRAINT_PRIMARYKEY:
      return PersistenceError.uniqueConstraintViolated(entity: entity, field: dbError.message ?? "unknown")
    case .SQLITE_BUSY, .SQLITE_BUSY_TIMEOUT, .SQLITE_LOCKED:
      return PersistenceError.busy(reason: dbError.message ?? "database busy")
    default:
      return error
    }
  }

  /// Runs `body`, mapping any `DatabaseError` it throws. Use inside a `db.write { }` closure so
  /// constraint failures surface as `PersistenceError` at the repository boundary.
  static func run<T>(entity: String, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      throw map(error, entity: entity)
    }
  }
}
