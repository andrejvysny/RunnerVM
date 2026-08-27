import Foundation
import RunnerCore
import Testing

@Suite struct DoctorImageIntegrityTests {
  @Test func consistentLayerHasNoProblem() {
    let layer = DoctorImageIntegrity.LayerCheck(
      digest: "sha256:abc", recordedBytes: 1_000, actualBytes: 1_000)
    #expect(layer.problem == nil)
  }

  @Test func missingBlobIsAProblem() throws {
    let layer = DoctorImageIntegrity.LayerCheck(
      digest: "sha256:abc", recordedBytes: 1_000, actualBytes: nil)
    let problem = try #require(layer.problem)
    #expect(problem.contains("missing"))
    #expect(problem.contains("sha256:abc"))
  }

  @Test func sizeMismatchIsAProblemNamingBothSizes() throws {
    let layer = DoctorImageIntegrity.LayerCheck(
      digest: "sha256:abc", recordedBytes: 1_000, actualBytes: 900)
    let problem = try #require(layer.problem)
    #expect(problem.contains("1000"))
    #expect(problem.contains("900"))
  }

  @Test func firstMismatchSkipsConsistentLayersAndStopsAtTheFirstProblem() {
    let checks: [(key: String, layer: DoctorImageIntegrity.LayerCheck)] = [
      ("sha256:ok1", .init(digest: "sha256:ok1", recordedBytes: 10, actualBytes: 10)),
      ("sha256:bad", .init(digest: "sha256:bad", recordedBytes: 10, actualBytes: 20)),
      ("sha256:ok2", .init(digest: "sha256:ok2", recordedBytes: 5, actualBytes: 5)),
      ("sha256:missing", .init(digest: "sha256:missing", recordedBytes: 5, actualBytes: nil)),
    ]
    let mismatch = DoctorImageIntegrity.firstMismatch(checks)
    #expect(mismatch?.key == "sha256:bad")
  }

  @Test func firstMismatchIsNilWhenEverythingIsConsistent() {
    let checks: [(key: String, layer: DoctorImageIntegrity.LayerCheck)] = [
      ("a", .init(digest: "a", recordedBytes: 10, actualBytes: 10)),
      ("b", .init(digest: "b", recordedBytes: 20, actualBytes: 20)),
    ]
    #expect(DoctorImageIntegrity.firstMismatch(checks) == nil)
  }
}
