import Foundation
import RunnerCore
import Testing

/// `doctor --output json` is a published contract (`scripts/qualify-host.sh` parses it), and the
/// `skip` status added for mode-aware checks must not turn into a failure anywhere.
@Suite struct DoctorModelTests {
  private static func roundTrip(_ check: DoctorCheck) throws -> DoctorCheck {
    let data = try JSONEncoder().encode(check)
    return try JSONDecoder().decode(DoctorCheck.self, from: data)
  }

  @Test func everyStatusRoundTripsThroughJSON() throws {
    for status in DoctorCheck.Status.allCases {
      let check = DoctorCheck(id: "x", title: "X", status: status, detail: "d")
      #expect(try Self.roundTrip(check) == check)
    }
  }

  @Test func statusEncodesAsItsBareName() throws {
    let data = try JSONEncoder().encode(
      DoctorCheck(id: "login_keychain", title: "Login keychain", status: .skip, detail: "n/a"))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"status\":\"skip\""))
    // Field names are the contract; qualify-host.sh greps for exactly these.
    for field in ["\"id\"", "\"title\"", "\"status\"", "\"detail\""] {
      #expect(json.contains(field))
    }
  }

  @Test func statusCasesAreExactlyTheFourKnownNames() {
    #expect(DoctorCheck.Status.allCases.map(\.rawValue) == ["ok", "warn", "fail", "skip"])
    #expect(DoctorCheck.Status(rawValue: "skip") == .skip)
    #expect(DoctorCheck.Status(rawValue: "unknown") == nil)
  }

  @Test func hasFailuresIgnoresWarnAndSkip() {
    let report = DoctorReport(checks: [
      DoctorCheck(id: "a", title: "A", status: .ok, detail: ""),
      DoctorCheck(id: "b", title: "B", status: .warn, detail: ""),
      DoctorCheck(id: "c", title: "C", status: .skip, detail: ""),
    ])
    #expect(!report.hasFailures)
  }

  @Test func hasFailuresIsTrueForASingleFail() {
    let report = DoctorReport(checks: [
      DoctorCheck(id: "a", title: "A", status: .skip, detail: ""),
      DoctorCheck(id: "b", title: "B", status: .fail, detail: ""),
    ])
    #expect(report.hasFailures)
  }

  @Test func emptyReportHasNoFailures() {
    #expect(!DoctorReport(checks: []).hasFailures)
  }

  @Test func countsAreCountedPerStatus() {
    let report = DoctorReport(checks: [
      DoctorCheck(id: "a", title: "A", status: .ok, detail: ""),
      DoctorCheck(id: "b", title: "B", status: .ok, detail: ""),
      DoctorCheck(id: "c", title: "C", status: .warn, detail: ""),
      DoctorCheck(id: "d", title: "D", status: .skip, detail: ""),
    ])
    #expect(report.count(of: .ok) == 2)
    #expect(report.count(of: .warn) == 1)
    #expect(report.count(of: .fail) == 0)
    #expect(report.count(of: .skip) == 1)
  }

  @Test func eachStatusRendersAsItsOwnSymbol() {
    let symbols = DoctorCheck.Status.allCases.map(DoctorStatusSymbol.symbol(for:))
    #expect(symbols == ["✓", "!", "✗", "-"])
    #expect(Set(symbols).count == symbols.count)
  }
}
