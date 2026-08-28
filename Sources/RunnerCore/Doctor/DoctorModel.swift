import Foundation

/// The result model behind `runnerctl doctor` (spec §104, §23).
///
/// Lives in `RunnerCore` rather than in `runnerctl` because there is no `runnerctl` test target:
/// the status semantics (what counts as a failure, how a status renders) are the part worth
/// pinning down in tests, and `Tests/RunnerCoreTests` is where the rest of doctor's pure helpers
/// are already tested. The JSON encoding is a published contract — `scripts/qualify-host.sh` reads
/// `{detail, id, status, title}` out of `doctor --output json` — so field names never change.
public struct DoctorCheck: Codable, Hashable, Sendable {
  /// `skip` means "not applicable to this host's mode or the inputs given" — a check that could
  /// not run and whose absence says nothing bad. `warn` stays reserved for "applicable, but
  /// degraded or unknown"; only `fail` makes `doctor` exit non-zero.
  public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
    case ok, warn, fail, skip
  }

  public var id: String
  public var title: String
  public var status: Status
  public var detail: String

  public init(id: String, title: String, status: Status, detail: String) {
    self.id = id
    self.title = title
    self.status = status
    self.detail = detail
  }
}

public struct DoctorReport: Codable, Hashable, Sendable {
  public var checks: [DoctorCheck]

  public init(checks: [DoctorCheck]) {
    self.checks = checks
  }

  /// Only `.fail` is a failure. A warning is an operator's judgement call and a skip is a
  /// non-event; neither may turn `doctor` into a non-zero exit.
  public var hasFailures: Bool {
    checks.contains { $0.status == .fail }
  }

  public func count(of status: DoctorCheck.Status) -> Int {
    checks.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
  }
}

/// How a status renders in the human table. Pure, and here rather than in the CLI so the mapping
/// is covered by the same tests as the model.
public enum DoctorStatusSymbol {
  public static func symbol(for status: DoctorCheck.Status) -> String {
    switch status {
    case .ok: "✓"
    case .warn: "!"
    case .fail: "✗"
    case .skip: "-"
    }
  }
}
