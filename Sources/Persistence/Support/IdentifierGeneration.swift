import Foundation

extension String {
  /// UUID-based identifier for tables with no RunnerCore typed ID (`scale_sets.id`,
  /// `job_summaries.id`, `audit_events.id`), matching `TypedID.generate()`'s convention
  /// (`Sources/RunnerCore/IDs.swift`).
  static func generateID() -> String { UUID().uuidString.lowercased() }
}
